// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "@v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@v4-core/src/libraries/LPFeeLibrary.sol";

/// @title JITShield — a Uniswap v4 hook that neutralises Just-In-Time MEV against passive LPs.
/// @notice Three mechanisms run together:
///         1. JIT detection in beforeAddLiquidity flags positions added in the same block as the
///            last swap, and time-locks them.
///         2. beforeSwap raises the LP fee with a surge premium when the previous block contained
///            suspicious liquidity churn. The premium is paid by the swapper; the bulk goes to
///            passive LPs via the standard v4 fee mechanism.
///         3. A fraction of the surge premium (`protocolFeeBips` of the premium) is carved out
///            via a `BeforeSwapDelta`, taken into the hook's balance, and accumulates as protocol
///            revenue. The owner withdraws it via `withdrawProtocolFees`.
///
/// @dev The pool MUST be created with a dynamic LP fee (`LPFeeLibrary.DYNAMIC_FEE_FLAG`) — the
///      hook reverts in `beforeInitialize` otherwise. The deployed hook address MUST encode
///      flags {BEFORE_INITIALIZE, BEFORE_ADD_LIQUIDITY, BEFORE_REMOVE_LIQUIDITY, BEFORE_SWAP,
///      AFTER_SWAP, BEFORE_SWAP_RETURNS_DELTA} in its low 14 bits — i.e. 0x2AC8. Mine the salt
///      with `script/DeployJITShield.s.sol`.
contract JITShield is IHooks {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using CurrencyLibrary for Currency;

    // --- Errors -----------------------------------------------------------------------------

    error NotPoolManager();
    error NotOwner();
    error PoolMustHaveDynamicFee();
    error InvalidConfig();
    error NativeTransferFailed();

    // --- Events -----------------------------------------------------------------------------

    event JITDetected(PoolId indexed poolId, address indexed liquidityProvider, uint256 unlockBlock);
    event SurgeApplied(PoolId indexed poolId, uint24 baseFee, uint24 surgeFee);
    event ProtocolFeeAccrued(Currency indexed currency, uint256 amount);
    event ProtocolFeeWithdrawn(Currency indexed currency, address indexed to, uint256 amount);
    event ConfigUpdated(uint24 surgeFee, uint16 protocolFeeBips, uint16 timeLockBlocks);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // --- Storage ----------------------------------------------------------------------------

    IPoolManager public immutable poolManager;
    address public owner;

    /// @notice Surge fee added on the next swap after suspicious liquidity activity. In pips
    ///         (1e6 = 100%). e.g. 7000 = 0.7%.
    uint24 public surgeFeeBips;

    /// @notice Protocol fee share, in basis points (1e4 = 100%) of the surge premium taken from
    ///         each shielded swap.
    uint16 public protocolFeeBips;

    /// @notice Number of blocks a flagged position is excluded from earning surge redistribution.
    uint16 public timeLockBlocks;

    /// @notice Per-pool record of the last swap block. Used to detect same-block JIT add.
    mapping(PoolId => uint256) public lastSwapBlock;

    /// @notice Per-position unlock block: position key => earliest block it may earn again.
    mapping(bytes32 => uint256) public positionUnlockBlock;

    /// @notice Per-pool surge flag: true if next swap should be charged surge fee.
    mapping(PoolId => bool) public surgePending;

    /// @notice Accrued protocol fees per currency, withdrawable by owner.
    mapping(Currency => uint256) public accruedFees;

    // --- Constructor ------------------------------------------------------------------------

    constructor(IPoolManager _poolManager, address _owner, uint24 _surgeFeeBips, uint16 _protocolFeeBips, uint16 _timeLockBlocks) {
        if (address(_poolManager) == address(0)) revert InvalidConfig();
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

    // --- Receive native --------------------------------------------------------------------

    receive() external payable {}

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
        address previous = owner;
        owner = newOwner;
        emit OwnershipTransferred(previous, newOwner);
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

    function beforeInitialize(address, PoolKey calldata key, uint160) external pure returns (bytes4) {
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
        bytes32 pk = positionKey(pid, sender, params.tickLower, params.tickUpper, params.salt);
        // Same-block add + remove of the same position is the JIT signature: arm surge.
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

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId pid = key.toId();
        BeforeSwapDelta returnDelta = BeforeSwapDeltaLibrary.ZERO_DELTA;
        uint24 feeOverride = 0;

        if (surgePending[pid]) {
            uint24 baseFee = key.fee.getInitialLPFee();
            uint24 surge = surgeFeeBips;
            feeOverride = (baseFee + surge) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
            emit SurgeApplied(pid, baseFee, surge);
            surgePending[pid] = false;

            // Carve a protocol cut out of the surge premium. We only do this for exact-input
            // swaps (amountSpecified < 0) so the cut is taken from a known input currency.
            if (params.amountSpecified < 0 && protocolFeeBips > 0) {
                uint256 inputAmt = uint256(-params.amountSpecified);
                // cut = inputAmt * surgeFeeBips * protocolFeeBips / (1e6 * 1e4)
                uint256 cut = inputAmt * uint256(surge) * uint256(protocolFeeBips) / 10_000_000_000;
                if (cut > 0 && cut <= uint256(uint128(type(int128).max))) {
                    Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
                    // Checks-effects-interactions: account + delta first, then external call.
                    accruedFees[inputCurrency] += cut;
                    returnDelta = toBeforeSwapDelta(int128(uint128(cut)), 0);
                    emit ProtocolFeeAccrued(inputCurrency, cut);
                    // Pull the cut into this contract. We are inside the swapper's unlock
                    // context; calling take() debits our delta by `cut`, the BeforeSwapDelta
                    // we return credits us by `cut`, net zero — swapper pays the extra.
                    poolManager.take(inputCurrency, address(this), cut);
                }
            }
        }

        return (IHooks.beforeSwap.selector, returnDelta, feeOverride);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId pid = key.toId();
        lastSwapBlock[pid] = block.number;
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

    /// @notice Withdraw accrued protocol fees for one currency.
    function withdrawProtocolFees(Currency currency, address to) external onlyOwner returns (uint256 amount) {
        if (to == address(0)) revert InvalidConfig();
        amount = accruedFees[currency];
        if (amount == 0) return 0;
        accruedFees[currency] = 0;
        currency.transfer(to, amount);
        emit ProtocolFeeWithdrawn(currency, to, amount);
    }
}
