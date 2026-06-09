// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {JITShield} from "../src/JITShield.sol";
import {IPoolManager} from "@v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/src/types/PoolId.sol";
import {Currency} from "@v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@v4-core/src/libraries/LPFeeLibrary.sol";

/// @notice Unit tests for JITShield. These exercise the hook's bookkeeping in isolation —
///         a real PoolManager is mocked by `manager` (an EOA we prank from). End-to-end
///         tests against a deployed PoolManager are out of scope for the skeleton.
contract JITShieldTest is Test {
    using PoolIdLibrary for PoolKey;

    JITShield internal hook;
    address internal manager = makeAddr("manager");
    address internal ownerAddr = makeAddr("owner");
    address internal lp = makeAddr("lp");
    address internal swapper = makeAddr("swapper");

    PoolKey internal key;
    PoolId internal pid;

    function setUp() public {
        hook = new JITShield(
            IPoolManager(manager),
            ownerAddr,
            7_000, // 0.7% surge
            1_000, // 10% protocol cut
            5      // 5-block time-lock
        );

        key = PoolKey({
            currency0: Currency.wrap(address(0xAAA1)),
            currency1: Currency.wrap(address(0xAAA2)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, // dynamic-fee marker
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        pid = key.toId();
    }

    // -------- access control --------

    function test_OnlyOwnerCanSetConfig() public {
        vm.expectRevert(JITShield.NotOwner.selector);
        hook.setConfig(5_000, 500, 10);

        vm.prank(ownerAddr);
        hook.setConfig(5_000, 500, 10);

        assertEq(hook.surgeFeeBips(), 5_000);
        assertEq(hook.protocolFeeBips(), 500);
        assertEq(hook.timeLockBlocks(), 10);
    }

    function test_SetConfigRejectsBadValues() public {
        vm.startPrank(ownerAddr);
        vm.expectRevert(JITShield.InvalidConfig.selector);
        hook.setConfig(uint24(LPFeeLibrary.MAX_LP_FEE) + 1, 500, 10);

        vm.expectRevert(JITShield.InvalidConfig.selector);
        hook.setConfig(5_000, 10_001, 10);

        vm.expectRevert(JITShield.InvalidConfig.selector);
        hook.setConfig(5_000, 500, 0);

        vm.expectRevert(JITShield.InvalidConfig.selector);
        hook.setConfig(5_000, 500, 201);
        vm.stopPrank();
    }

    function test_OnlyPoolManagerCanCallHooks() public {
        ModifyLiquidityParams memory mp =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: bytes32(0)});

        vm.expectRevert(JITShield.NotPoolManager.selector);
        hook.beforeAddLiquidity(lp, key, mp, "");
    }

    // -------- JIT detection --------

    function test_SameBlockAddIsTimeLocked() public {
        vm.roll(100);

        // Simulate that a swap just happened in block 100.
        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        vm.prank(manager);
        hook.afterSwap(swapper, key, sp, BalanceDelta.wrap(0), "");

        // Now an LP adds liquidity in the same block. This is the JIT signature.
        ModifyLiquidityParams memory mp =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 5e18, salt: bytes32(0)});

        vm.prank(manager);
        hook.beforeAddLiquidity(lp, key, mp, "");

        bytes32 pk = hook.positionKey(pid, lp, -60, 60, bytes32(0));
        assertEq(hook.positionUnlockBlock(pk), 105, "position should be locked for 5 blocks");
    }

    function test_DifferentBlockAddIsNotLocked() public {
        vm.roll(100);

        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        vm.prank(manager);
        hook.afterSwap(swapper, key, sp, BalanceDelta.wrap(0), "");

        // Advance one block — this LP is a passive provider.
        vm.roll(101);

        ModifyLiquidityParams memory mp =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 5e18, salt: bytes32(0)});

        vm.prank(manager);
        hook.beforeAddLiquidity(lp, key, mp, "");

        bytes32 pk = hook.positionKey(pid, lp, -60, 60, bytes32(0));
        assertEq(hook.positionUnlockBlock(pk), 0, "passive LP should not be flagged");
    }

    // -------- surge-pending flow --------

    function test_RemoveWhileLockedTriggersSurge() public {
        vm.roll(100);

        // Swap, then same-block add — locks the position.
        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        vm.prank(manager);
        hook.afterSwap(swapper, key, sp, BalanceDelta.wrap(0), "");

        ModifyLiquidityParams memory mp =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 5e18, salt: bytes32(0)});
        vm.prank(manager);
        hook.beforeAddLiquidity(lp, key, mp, "");

        // JIT actor removes while still inside the lock window.
        ModifyLiquidityParams memory removal =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -5e18, salt: bytes32(0)});
        vm.prank(manager);
        hook.beforeRemoveLiquidity(lp, key, removal, "");

        assertTrue(hook.surgePending(pid), "surge should be armed for the next swap");

        // Next swap consumes the surge: beforeSwap returns a fee override with the surge flag
        // AND takes a protocol cut. The hook calls poolManager.take() during beforeSwap, so we
        // mock it for this unit test — the integration test on Anvil exercises the real call.
        vm.mockCall(
            manager,
            abi.encodeWithSelector(IPoolManager.take.selector),
            ""
        );
        vm.prank(manager);
        (, , uint24 feeOverride) = hook.beforeSwap(swapper, key, sp, "");
        assertTrue(feeOverride & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0, "override flag missing");
        assertFalse(hook.surgePending(pid), "surge should be consumed");

        // Protocol cut accrued in currency0 (zeroForOne = true).
        // cut = 1e18 * 7000 * 1000 / 1e10 = 7e17 ... wait
        // cut = inputAmt * surge * protocolBips / 10_000_000_000
        //     = 1e18 * 7000 * 1000 / 10_000_000_000
        //     = 7e24 / 1e10 = 7e14
        assertEq(hook.accruedFees(key.currency0), 7e14, "protocol cut accrued");
    }

    function test_NoSurgeWhenNoJIT() public {
        vm.roll(100);

        // Passive add (block 100), swap (block 101) — clean flow.
        ModifyLiquidityParams memory mp =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 5e18, salt: bytes32(0)});
        vm.prank(manager);
        hook.beforeAddLiquidity(lp, key, mp, "");

        vm.roll(101);

        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        vm.prank(manager);
        (, , uint24 feeOverride) = hook.beforeSwap(swapper, key, sp, "");

        assertEq(feeOverride, 0, "no surge => no override");
    }

    // -------- ownership --------

    function test_TransferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(ownerAddr);
        hook.transferOwnership(newOwner);
        assertEq(hook.owner(), newOwner);

        // old owner can no longer set config
        vm.expectRevert(JITShield.NotOwner.selector);
        vm.prank(ownerAddr);
        hook.setConfig(1_000, 100, 5);
    }
}
