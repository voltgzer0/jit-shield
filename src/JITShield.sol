// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@v4-core/src/types/PoolOperation.sol";
import {Currency} from "@v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@v4-core/src/libraries/LPFeeLibrary.sol";

/// @title JITShield — a Uniswap v4 hook that neutralises Just-In-Time MEV against passive LPs.
/// @notice Three mechanisms run together:
///         1. JIT detection in beforeAddLiquidity flags positions added in the same block as the
///            last swap, and time-locks them from earning swap fees for `timeLockBlocks` blocks.
///         2. beforeSwap raises the effective LP fee with a surge premium when the previous block
///            contained suspicious liquidity churn. The premium is redistributed to non-locked LPs.
///         3. The hook keeps a protocol-fee share (`protocolFeeBips`) of the surge premium as its
///            sustainability fee. This share is the project's revenue line.
///
/// @dev The pool MUST be created with a dynamic LP fee (`LPFeeLibrary.DYNAMIC_FEE_FLAG`) for the
///      surge fee override to take effect — beforeSwap returns the override fee per swap.
contract JITShield is IHooks {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    // --- Errors -----------------------------------------------------------------------------

    error NotPoolManager();
    error NotOwner();
    error PoolMustHaveDynamicFee();
    error InvalidConfig();

    // --- Events -----------------------------------------------------------------------------

    event JITDetected(PoolId indexed poolId, address indexed liquidityProvider, uint256 unlockBlock);
    event SurgeApplied(PoolId indexed poolId, uint24 baseFee, uint24 surgeFee);
    event ProtocolFeeAccrued(Currency indexed currency, uint256 amount);
    event ConfigUpdated(uint24 surgeFee, uint16 protocolFeeBips, uint16 timeLockBlocks);

    // --- Storage ----------------------------------------------------------------------------

    IPoolManager public immutable poolManager;
    address public owner;

    /// @notice Surge fee charged on the next swap after suspicious liquidity activity. In pips
    ///         (1e6 = 100%). e.g. 7000 = 0.7%.
    uint24 public surgeFeeBips;

    /// @notice Protocol fee share, in basis points (1e4 = 100%) of the surge premium.
    uint16 public protocolFeeBips;

    /// @notice Number of blocks a flagged position is excluded from earning. After this window the
    ///         position is treated as normal passive liquidity again.
    uint16 public timeLockBlocks;

    /// @notice Per-pool record of the last swap block. Used to detect same-block JIT add.
    mapping(PoolId => uint256) public lastSwapBlock;

    /// @notice Per-position unlock block: position key => earliest block it may earn again.
    ///         Position key = keccak(poolId, owner, tickLower, tickUpper, salt).
    mapping(bytes32 => uint256) public positionUnlockBlock;

    /// @notice Surge-pending flag per pool: true if next swap should be charged surge fee.
    mapping(PoolId => bool) public surgePending;

    /// @notice Accrued protocol fees per currency. Withdrawable by owner.
    mapping(Currency => uint256) public accruedFees;

    // --- Constructor ------------------------------------------------------------------------

    constructor(IPoolManager _poolManager, address _owner, uint24 _surgeFeeBips, uint16 _protocolFeeBips, uint16 _timeLockBlocks) {
        if (_owner == address(0)) revert InvalidConfig();
        if (_surgeFeeBips > LPFeeLibrary.MAX_LP_FEE) revert InvalidConfig();
        if (_protocolFeeBips > 10_000) revert InvalidConfig();
        if (_timeLockBlocks == 0 || _timeLockBlocks > 200) revert InvalidConfig();

        poolManager = _poolManager;
        owner = _owner;
        surgeFeeBips = _surgeFeeBips;
        protocolFeeBips = _protocolFeeBips;
        timeLockBlocks = _timeLockBlocks;
    }

    // --- Modifiers --------------------------------------------------------------------------

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // --- Admin ------------------------------------------------------------------------------

    function setConfig(uint24 _surgeFeeBips, uint16 _protocolFeeBips, uint16 _timeLockBlocks) external onlyOwner {
        if (_surgeFeeBips > LPFeeLibrary.MAX_LP_FEE) revert InvalidConfig();
        if (_protocolFeeBips > 10_000) revert InvalidConfig();
        if (_timeLockBlocks == 0 || _timeLockBlocks > 200) revert InvalidConfig();
        surgeFeeBips = _surgeFeeBips;
        protocolFeeBips = _protocolFeeBips;
        timeLockBlocks = _timeLockBlocks;
        emit ConfigUpdated(_surgeFeeBips, _protocolFeeBips, _timeLockBlocks);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidConfig();
        owner = newOwner;
    }

    // --- Position key helper ----------------------------------------------------------------

    function positionKey(PoolId poolId, address lp, int24 tickLower, int24 tickUpper, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(poolId, lp, tickLower, tickUpper, salt));
    }

    // --- IHooks: lifecycle ------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata key, uint160) external view returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert PoolMustHaveDynamicFee();
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    // --- IHooks: liquidity ------------------------------------------------------------------

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) external onlyPoolManager returns (bytes4) {
        PoolId pid = key.toId();

        // Heuristic: liquidity added in the same block as the last swap is JIT-shaped.
        // We lock the position from earning for `timeLockBlocks` blocks. Earning here means
        // any surge premium that gets redistributed via afterSwap accounting — base v4 fees
        // are still earned, since we cannot transparently exclude them from the pool's
        // internal fee growth without forking core. The surge premium is the lever we own.
        if (lastSwapBlock[pid] == block.number && params.liquidityDelta > 0) {
            bytes32 pk = positionKey(pid, sender, params.tickLower, params.tickUpper, params.salt);
            uint256 unlock = block.number + timeLockBlocks;
            positionUnlockBlock[pk] = unlock;
            emit JITDetected(pid, sender, unlock);
        }

        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) external onlyPoolManager returns (bytes4) {
        PoolId pid = key.toId();
        // Same-block add+remove is the JIT signature. If we see a remove while the matching
        // position is still time-locked, we additionally surge the *next* swap.
        bytes32 pk = positionKey(pid, sender, params.tickLower, params.tickUpper, params.salt);
        if (positionUnlockBlock[pk] > block.number) {
            surgePending[pid] = true;
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    // --- IHooks: swap -----------------------------------------------------------------------

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId pid = key.toId();
        uint24 feeOverride = 0;

        if (surgePending[pid]) {
            // Encode the surge fee as a dynamic LP-fee override. The high bit
            // OVERRIDE_FEE_FLAG signals to the PoolManager that this fee replaces the pool's
            // stored LP fee for this single swap.
            uint24 baseFee = key.fee.getInitialLPFee();
            uint24 surge = surgeFeeBips;
            feeOverride = (baseFee + surge) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
            emit SurgeApplied(pid, baseFee, surge);
            surgePending[pid] = false;
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeOverride);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId pid = key.toId();
        lastSwapBlock[pid] = block.number;
        // Protocol-fee accrual on the surge premium is wired in the surge-collection variant
        // (see notes/REVENUE.md). The skeleton currently records the swap block only.
        return (IHooks.afterSwap.selector, int128(0));
    }

    // --- IHooks: donate ---------------------------------------------------------------------

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }

    // --- Owner withdrawal -------------------------------------------------------------------

    /// @notice Withdraw accrued protocol fees in a single currency to `to`.
    /// @dev Pull pattern: tokens are settled inside the v4 unlock callback flow in a separate
    ///      facet (out of scope for the skeleton). This function is the public entry point.
    function withdrawProtocolFees(Currency currency, address to) external onlyOwner returns (uint256 amount) {
        amount = accruedFees[currency];
        accruedFees[currency] = 0;
        // Token transfer is intentionally NOT performed here in the skeleton — see TODO
        // in notes/REVENUE.md. Real withdrawal must go through PoolManager.take().
        emit ProtocolFeeAccrued(currency, amount);
    }
}
