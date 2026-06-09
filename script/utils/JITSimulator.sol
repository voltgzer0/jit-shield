// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@v4-core/src/types/PoolKey.sol";
import {Currency} from "@v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "@v4-core/test/utils/CurrencySettler.sol";

/// @notice Testnet-only helper: drives the entire JIT scenario inside a single PoolManager
///         unlock so all four ops (primer swap, JIT add, JIT remove, final swap) execute in
///         the same block. This is the only way to legitimately exercise the same-block
///         heuristic on a real chain — separate broadcast txs would land in different blocks
///         and silently skip the JIT detection branch.
contract JITSimulator is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    struct Scenario {
        PoolKey key;
        int128 jitLiquidity;
        int24 jitTickLower;
        int24 jitTickUpper;
        bytes32 jitSalt;
        int256 primerSwapAmount; // negative = exact-input
        int256 finalSwapAmount;  // negative = exact-input
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function runScenario(Scenario calldata s) external {
        manager.unlock(abi.encode(s));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        Scenario memory s = abi.decode(raw, (Scenario));

        // Step 1: primer swap, token0 → token1, tiny — arms lastSwapBlock for JIT detection.
        _swap(s.key, true, s.primerSwapAmount);

        // Step 2: JIT searcher adds tight-range liquidity, same block as the primer swap.
        _modify(s.key, s.jitTickLower, s.jitTickUpper, s.jitLiquidity, s.jitSalt);

        // Step 3: JIT searcher removes same-block, exiting before the next swap settles. The
        //         hook sees the position is still time-locked and arms surge on this pool.
        _modify(s.key, s.jitTickLower, s.jitTickUpper, -s.jitLiquidity, s.jitSalt);

        // Step 4: final swap, token0 → token1, larger — pays surge premium; the hook carves
        //         its protocol cut from the input via BeforeSwapDelta + manager.take.
        _swap(s.key, true, s.finalSwapAmount);

        return "";
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal {
        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        _settleDelta(key, delta);
    }

    function _modify(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        bytes32 salt
    ) internal {
        (BalanceDelta delta, ) = manager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: salt
            }),
            ""
        );
        _settleDelta(key, delta);
    }

    function _settleDelta(PoolKey memory key, BalanceDelta delta) internal {
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        if (a0 < 0) key.currency0.settle(manager, address(this), uint256(uint128(-a0)), false);
        if (a1 < 0) key.currency1.settle(manager, address(this), uint256(uint128(-a1)), false);
        if (a0 > 0) key.currency0.take(manager, address(this), uint256(uint128(a0)), false);
        if (a1 > 0) key.currency1.take(manager, address(this), uint256(uint128(a1)), false);
    }
}
