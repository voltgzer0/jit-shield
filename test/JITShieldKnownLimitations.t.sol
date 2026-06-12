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

/// @notice Documents known detection gaps so the threat model is honest. Each test pins
/// a scenario the current heuristic does NOT catch; assertions describe today's behavior
/// (so regressions show up as red), and the comment block above each test names the gap.
contract JITShieldKnownLimitationsTest is Test {
    using PoolIdLibrary for PoolKey;

    JITShield internal hook;
    address internal manager = makeAddr("manager");
    address internal ownerAddr = makeAddr("owner");
    address internal bot = makeAddr("bot");
    address internal victim = makeAddr("victim");

    PoolKey internal key;
    PoolId internal pid;

    function setUp() public {
        hook = new JITShield(IPoolManager(manager), ownerAddr, 7_000, 1_000, 5);
        key = PoolKey({
            currency0: Currency.wrap(address(0xAAA1)),
            currency1: Currency.wrap(address(0xAAA2)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        pid = key.toId();
    }

    /// @notice GAP-1 (CLASSICAL JIT PATTERN).
    ///
    /// Pattern: ADD → SWAP → REMOVE in a single block, ADD is the first operation.
    /// This is the most common JIT shape in the wild: the bot adds liquidity right before
    /// a known incoming swap, the swap executes against its tight range, the bot removes
    /// at the end of the block.
    ///
    /// The current heuristic in `beforeAddLiquidity` requires `lastSwapBlock[pid] ==
    /// block.number`, i.e. a swap must have ALREADY happened in this block before the
    /// add. In the classical pattern there is no prior swap, so the position is never
    /// flagged. `beforeRemoveLiquidity` reads `positionUnlockBlock[pk]` which stays 0,
    /// so surge is never armed. The bot extracts value and walks away clean.
    function test_GAP1_ClassicalAddFirstJIT_NotDetected() public {
        vm.roll(100);

        // 1. Bot ADD (first op in the block).
        ModifyLiquidityParams memory add =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 5e18, salt: bytes32(0)});
        vm.prank(manager);
        hook.beforeAddLiquidity(bot, key, add, "");

        bytes32 pk = hook.positionKey(pid, bot, -60, 60, bytes32(0));
        assertEq(hook.positionUnlockBlock(pk), 0, "GAP-1: position not flagged");

        // 2. Victim SWAP.
        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        vm.prank(manager);
        (, , uint24 feeOverride) = hook.beforeSwap(victim, key, sp, "");
        assertEq(feeOverride, 0, "GAP-1: no surge fee charged");
        vm.prank(manager);
        hook.afterSwap(victim, key, sp, BalanceDelta.wrap(0), "");

        // 3. Bot REMOVE.
        ModifyLiquidityParams memory remove =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -5e18, salt: bytes32(0)});
        vm.prank(manager);
        hook.beforeRemoveLiquidity(bot, key, remove, "");
        assertFalse(hook.surgePending(pid), "GAP-1: surge never armed for the JIT");

        // No protocol cut accrued.
        assertEq(hook.accruedFees(key.currency0), 0, "GAP-1: zero protocol revenue from this JIT");
    }

    /// @notice GAP-2 CLOSED (ROUTER LAUNDERING RESISTANT).
    ///
    /// Position key is `keccak256(poolId, sender, tickLower, tickUpper, salt)` where
    /// `sender` is the address that called PoolManager — typically a router. A naive
    /// implementation would arm surge only in `beforeRemoveLiquidity`, so a bot could
    /// add through Router A and remove through Router B to avoid the surge (the
    /// position keys would not match).
    ///
    /// The fix in `beforeAddLiquidity` arms `surgePending[pid]` directly when JIT-shape
    /// is detected. The bot's back-run swap is then charged the surge regardless of
    /// whether the position is ever removed through the same router. This test pins the
    /// resistance so a regression would be visible.
    function test_GAP2_Closed_RouterLaunderingDoesNotBypassSurge() public {
        vm.roll(100);

        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        vm.prank(manager);
        hook.afterSwap(victim, key, sp, BalanceDelta.wrap(0), "");

        address routerA = makeAddr("routerA");
        address routerB = makeAddr("routerB");

        ModifyLiquidityParams memory add =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 5e18, salt: bytes32(0)});
        vm.prank(manager);
        hook.beforeAddLiquidity(routerA, key, add, "");

        // Surge is armed at ADD time — does not depend on the bot using the same router
        // for the matching remove. The next swap pays the penalty.
        assertTrue(hook.surgePending(pid), "GAP-2 closed: surge armed at add, not at remove");

        // Remove through Router B is irrelevant for the surge mechanism after the fix.
        ModifyLiquidityParams memory remove =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -5e18, salt: bytes32(0)});
        vm.prank(manager);
        hook.beforeRemoveLiquidity(routerB, key, remove, "");
        assertTrue(hook.surgePending(pid), "GAP-2 closed: still armed after foreign-router remove");
    }

    /// @notice Fix verification: native ETH sent directly to the hook (e.g. accidental
    /// transfer, or future flows where PoolManager.take on the NATIVE currency forwards
    /// ETH) is credited to the protocol-fee escrow and the owner can withdraw it.
    function test_NativeETHReceiveIsRecoverable() public {
        address donor = makeAddr("donor");
        vm.deal(donor, 1 ether);

        vm.prank(donor);
        (bool ok, ) = address(hook).call{value: 1 ether}("");
        assertTrue(ok, "receive should accept ETH");

        // Credited under the NATIVE sentinel (Currency.wrap(address(0))).
        assertEq(hook.accruedFees(Currency.wrap(address(0))), 1 ether, "accrued under native");

        // Owner can withdraw.
        address recipient = makeAddr("recipient");
        vm.prank(ownerAddr);
        uint256 amount = hook.withdrawProtocolFees(Currency.wrap(address(0)), recipient);
        assertEq(amount, 1 ether);
        assertEq(recipient.balance, 1 ether);
        assertEq(hook.accruedFees(Currency.wrap(address(0))), 0);
    }
}
