// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@v4-core/test/utils/Deployers.sol";
import {JITShield} from "../src/JITShield.sol";
import {Hooks} from "@v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@v4-core/src/types/PoolOperation.sol";
import {Currency} from "@v4-core/src/types/Currency.sol";

/// @notice End-to-end integration test against a real PoolManager. Spins up a v4 pool with the
///         JITShield hook, simulates a JIT attack (swap → same-block add → same-block remove),
///         then verifies that the surge fee fires on the next swap AND a protocol fee accrues
///         to the hook in the input currency.
contract JITShieldIntegrationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    JITShield internal hook;
    address internal ownerAddr = makeAddr("hookOwner");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Etch JITShield at an address whose low 14 bits encode the required hook flags. We use
        // deployCodeTo (a Forge cheat) instead of CREATE2 mining for test speed — the production
        // deploy uses the HookMiner-based DeployJITShield.s.sol script.
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        address target = address(uint160(0x4444000000000000000000000000000000000000) | uint160(flags));
        deployCodeTo(
            "JITShield.sol:JITShield",
            abi.encode(manager, ownerAddr, uint24(7000), uint16(1000), uint16(5)),
            target
        );
        hook = JITShield(payable(target));

        // Initialize a dynamic-fee pool with the hook. Deployers' initPool picks tickSpacing=60
        // for dynamic-fee pools, which matches LIQUIDITY_PARAMS (-120, 120).
        (key,) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
    }

    function test_HookAddressEncodesFlags() public view {
        uint160 expected = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, expected);
    }

    function test_PassiveLPDoesNotGetLocked() public {
        // No swap has happened, so adding liquidity in this block is plain passive provision.
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        bytes32 pk = hook.positionKey(
            key.toId(),
            address(modifyLiquidityRouter),
            LIQUIDITY_PARAMS.tickLower,
            LIQUIDITY_PARAMS.tickUpper,
            LIQUIDITY_PARAMS.salt
        );
        assertEq(hook.positionUnlockBlock(pk), 0, "passive add must not be locked");
    }

    function test_EndToEnd_JITAttackTriggersSurgeAndAccruesProtocolFee() public {
        PoolId pid = key.toId();

        // ---- 1. Passive LP seeds deep range so the pool can swap. -------------------------
        ModifyLiquidityParams memory passive = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 1e21,
            salt: bytes32(uint256(1))
        });
        modifyLiquidityRouter.modifyLiquidity(key, passive, ZERO_BYTES);

        // ---- 2. A small swap primes lastSwapBlock. ----------------------------------------
        swap(key, true, -1e15, ZERO_BYTES);

        // ---- 3. JIT searcher adds a tight position in the SAME block. ---------------------
        ModifyLiquidityParams memory jitAdd = ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: 1e21,
            salt: bytes32(uint256(2))
        });
        modifyLiquidityRouter.modifyLiquidity(key, jitAdd, ZERO_BYTES);

        bytes32 jitKey =
            hook.positionKey(pid, address(modifyLiquidityRouter), -60, 60, bytes32(uint256(2)));
        assertGt(hook.positionUnlockBlock(jitKey), block.number, "JIT position should be time-locked");

        // ---- 4. JIT removes in the same block → arms surge. -------------------------------
        ModifyLiquidityParams memory jitRemove = ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: -1e21,
            salt: bytes32(uint256(2))
        });
        modifyLiquidityRouter.modifyLiquidity(key, jitRemove, ZERO_BYTES);

        assertTrue(hook.surgePending(pid), "surge must be armed");

        // ---- 5. Next swap consumes the surge and accrues protocol fee. --------------------
        uint256 feesBefore = hook.accruedFees(currency0);
        swap(key, true, -1e18, ZERO_BYTES);
        uint256 feesAfter = hook.accruedFees(currency0);

        assertGt(feesAfter - feesBefore, 0, "protocol fee should accrue in currency0");
        assertFalse(hook.surgePending(pid), "surge should be consumed");

        // ---- 6. Owner withdraws. ----------------------------------------------------------
        uint256 hookBalanceBefore = currency0.balanceOf(address(hook));
        assertEq(hookBalanceBefore, feesAfter, "hook should hold the accrued tokens");

        vm.prank(ownerAddr);
        uint256 withdrawn = hook.withdrawProtocolFees(currency0, ownerAddr);
        assertEq(withdrawn, feesAfter, "withdraw should equal accrued");
        assertEq(currency0.balanceOf(ownerAddr), withdrawn, "owner should receive the tokens");
        assertEq(hook.accruedFees(currency0), 0, "accrued should be zeroed");
    }
}
