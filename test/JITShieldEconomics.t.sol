// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@v4-core/test/utils/Deployers.sol";
import {JITShield} from "../src/JITShield.sol";
import {Hooks} from "@v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@v4-core/src/types/PoolOperation.sol";
import {Currency} from "@v4-core/src/types/Currency.sol";

/// @notice Economics demonstration test. When `MAINNET_RPC_URL` is set the test forks Ethereum
///         mainnet at the latest block, otherwise it runs offline. The token contracts are mock
///         ERC20s for clarity — what matters is the surge premium and protocol-fee accrual on a
///         realistically-sized swap.
///
///         Run forked:
///           MAINNET_RPC_URL=https://ethereum.publicnode.com forge test \
///             --match-contract JITShieldEconomicsTest -vv
///
///         Run offline:
///           forge test --match-contract JITShieldEconomicsTest -vv
contract JITShieldEconomicsTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    JITShield internal hook;
    address internal ownerAddr = makeAddr("hookOwner");

    // Pool config knobs — matched to the README revenue model.
    uint24 constant SURGE_PIPS = 7_000;         // 0.7%
    uint16 constant PROTOCOL_BIPS = 1_000;      // 10% of the surge premium
    uint16 constant TIMELOCK_BLOCKS = 5;

    // Scenario knobs — choose numbers so the printed report is readable.
    uint128 constant PASSIVE_LIQUIDITY = 1e22;
    uint128 constant JIT_LIQUIDITY = 1e21;
    // 1 unit; we scale the report up by $-equivalents so the headline numbers are readable.
    int256 constant TARGET_SWAP_INPUT = 1e18;
    // Reference $-value used to scale the per-swap report (i.e. "assume this swap was worth $500k").
    uint256 constant REFERENCE_USD_PER_SWAP = 500_000;

    function setUp() public {
        // Optional fork — does not change the contract logic, just colour. ------------------
        try vm.envString("MAINNET_RPC_URL") returns (string memory rpc) {
            uint256 forkId = vm.createFork(rpc);
            vm.selectFork(forkId);
            console2.log("Forked mainnet at block", block.number);
        } catch {
            console2.log("Running offline (set MAINNET_RPC_URL to fork mainnet)");
        }

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        address target = address(uint160(0x4444000000000000000000000000000000000000) | uint160(flags));
        deployCodeTo(
            "JITShield.sol:JITShield",
            abi.encode(manager, ownerAddr, SURGE_PIPS, PROTOCOL_BIPS, TIMELOCK_BLOCKS),
            target
        );
        hook = JITShield(payable(target));

        (key,) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
    }

    function test_Report_JITScenarioEconomics() public {
        PoolId pid = key.toId();

        _printHeader();

        // ---- 1. Passive LP seeds deep liquidity. -----------------------------------------
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: int128(PASSIVE_LIQUIDITY),
                salt: bytes32(uint256(1))
            }),
            ZERO_BYTES
        );
        console2.log("[step 1] passive LP seeded liquidity:", uint256(PASSIVE_LIQUIDITY));

        // ---- 2. Primer swap to set lastSwapBlock. ----------------------------------------
        swap(key, true, -1e15, ZERO_BYTES);
        console2.log("[step 2] primer swap executed; lastSwapBlock now armed");

        // ---- 3. JIT searcher adds tight-range liquidity same-block. ----------------------
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int128(JIT_LIQUIDITY),
                salt: bytes32(uint256(2))
            }),
            ZERO_BYTES
        );
        bytes32 jitKey = hook.positionKey(pid, address(modifyLiquidityRouter), -60, 60, bytes32(uint256(2)));
        console2.log("[step 3] JIT same-block add detected; position time-locked until block", hook.positionUnlockBlock(jitKey));

        // ---- 4. JIT removes same-block → arm surge. --------------------------------------
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -int128(JIT_LIQUIDITY),
                salt: bytes32(uint256(2))
            }),
            ZERO_BYTES
        );
        require(hook.surgePending(pid), "surge not armed");
        console2.log("[step 4] JIT removed during lock window; surge armed for next swap");

        // ---- 5. Target swap consumes surge. ----------------------------------------------
        uint256 feesBefore = hook.accruedFees(currency0);
        swap(key, true, -TARGET_SWAP_INPUT, ZERO_BYTES);
        uint256 feesAfter = hook.accruedFees(currency0);
        uint256 protocolCut = feesAfter - feesBefore;

        // Theoretical surge premium = TARGET_SWAP_INPUT * SURGE_PIPS / 1e6
        uint256 surgePremium = uint256(TARGET_SWAP_INPUT) * SURGE_PIPS / 1_000_000;
        uint256 lpShare = surgePremium - protocolCut;

        _printReport(uint256(TARGET_SWAP_INPUT), surgePremium, protocolCut, lpShare);

        // ---- 6. Owner withdraws. ----------------------------------------------------------
        vm.prank(ownerAddr);
        hook.withdrawProtocolFees(currency0, ownerAddr);
        assertEq(currency0.balanceOf(ownerAddr), protocolCut, "owner received protocol cut");

        // Sanity: protocol cut should match the formula exactly.
        uint256 expected =
            uint256(TARGET_SWAP_INPUT) * uint256(SURGE_PIPS) * uint256(PROTOCOL_BIPS) / 10_000_000_000;
        assertEq(protocolCut, expected, "protocol cut formula");
    }

    function _printHeader() internal pure {
        console2.log("");
        console2.log("=============================================================");
        console2.log("           JITShield Economics Demonstration");
        console2.log("=============================================================");
        console2.log("Surge fee (pips, 1e6=100%):           7000  (= 0.7%)");
        console2.log("Protocol share of surge (bips):       1000  (= 10%)");
        console2.log("Time-lock window (blocks):              5");
        console2.log("-------------------------------------------------------------");
    }

    function _printReport(uint256 swapInput, uint256 surgePremium, uint256 protocolCut, uint256 lpShare)
        internal
        pure
    {
        // Ratios as parts-per-million for readable precision.
        uint256 surgeRatioPpm = surgePremium * 1_000_000 / swapInput;
        uint256 cutRatioPpm = protocolCut * 1_000_000 / swapInput;
        uint256 lpRatioPpm = lpShare * 1_000_000 / swapInput;

        // Scale to a reference $-sized swap.
        uint256 surgeUsd = REFERENCE_USD_PER_SWAP * surgeRatioPpm / 1_000_000;
        uint256 cutUsd = REFERENCE_USD_PER_SWAP * cutRatioPpm / 1_000_000;
        uint256 lpUsd = REFERENCE_USD_PER_SWAP * lpRatioPpm / 1_000_000;

        console2.log("");
        console2.log("---- Per-swap fractions (parts-per-million of input) ---");
        console2.log("Surge premium     :", surgeRatioPpm, "ppm");
        console2.log("  -> passive LPs  :", lpRatioPpm, "ppm");
        console2.log("  -> protocol     :", cutRatioPpm, "ppm");
        console2.log("");
        console2.log("---- Scaled to a $", REFERENCE_USD_PER_SWAP, "shielded swap ---");
        console2.log("Surge premium  USD:", surgeUsd);
        console2.log("  -> passive LPs  :", lpUsd);
        console2.log("  -> protocol     :", cutUsd);
        console2.log("");
        console2.log("---- Daily projection: 10 shielded swaps of that size ---");
        console2.log("LP daily USD      :", lpUsd * 10);
        console2.log("Protocol daily USD:", cutUsd * 10);
        console2.log("Protocol annual   :", cutUsd * 10 * 365);
        console2.log("=============================================================");
    }
}
