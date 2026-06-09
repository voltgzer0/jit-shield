// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/src/types/PoolId.sol";
import {Currency} from "@v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@v4-core/src/libraries/LPFeeLibrary.sol";
import {JITSimulator} from "./utils/JITSimulator.sol";
import {JITShield} from "../src/JITShield.sol";

interface IERC20Like {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Runs the live JIT scenario against the pool we initialised earlier on Sepolia.
///         Required env (all addresses):
///           POOL_MANAGER, JITSHIELD_HOOK, POOL_CURRENCY0, POOL_CURRENCY1
contract JITSimulateSepolia is Script {
    using PoolIdLibrary for PoolKey;

    int24 constant JIT_TICK_LOWER = -60;
    int24 constant JIT_TICK_UPPER = 60;
    int128 constant JIT_LIQUIDITY = 1e21;
    int256 constant PRIMER_SWAP = -1e16;   // 0.01 token, just enough to register a swap
    int256 constant FINAL_SWAP = -1e18;    // 1 token, large enough to make the cut visible

    function run() external {
        IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER"));
        JITShield hook = JITShield(payable(vm.envAddress("JITSHIELD_HOOK")));
        Currency c0 = Currency.wrap(vm.envAddress("POOL_CURRENCY0"));
        Currency c1 = Currency.wrap(vm.envAddress("POOL_CURRENCY1"));

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId pid = key.toId();

        // --- Pre-state -----------------------------------------------------------------
        uint256 feesC0Before = hook.accruedFees(c0);
        uint256 feesC1Before = hook.accruedFees(c1);
        bool surgeBefore = hook.surgePending(pid);
        uint256 lastSwapBlockBefore = hook.lastSwapBlock(pid);

        console2.log("===== PRE-SCENARIO STATE =====");
        console2.log("PoolId            :");
        console2.logBytes32(PoolId.unwrap(pid));
        console2.log("accruedFees[c0]   :", feesC0Before);
        console2.log("accruedFees[c1]   :", feesC1Before);
        console2.log("surgePending      :", surgeBefore);
        console2.log("lastSwapBlock     :", lastSwapBlockBefore);

        vm.startBroadcast();

        // --- Deploy the simulator and fund it ------------------------------------------
        JITSimulator sim = new JITSimulator(pm);
        console2.log("");
        console2.log("Simulator deployed:", address(sim));

        // Fund the simulator generously: 100 tokens of each.
        IERC20Like(Currency.unwrap(c0)).transfer(address(sim), 100e18);
        IERC20Like(Currency.unwrap(c1)).transfer(address(sim), 100e18);
        console2.log("Funded simulator with 100 c0 + 100 c1");

        // --- Run the atomic scenario in a single tx ------------------------------------
        sim.runScenario(JITSimulator.Scenario({
            key: key,
            jitLiquidity: JIT_LIQUIDITY,
            jitTickLower: JIT_TICK_LOWER,
            jitTickUpper: JIT_TICK_UPPER,
            jitSalt: bytes32(uint256(0xDEAD)),
            primerSwapAmount: PRIMER_SWAP,
            finalSwapAmount: FINAL_SWAP
        }));

        vm.stopBroadcast();

        // --- Post-state ----------------------------------------------------------------
        uint256 feesC0After = hook.accruedFees(c0);
        uint256 feesC1After = hook.accruedFees(c1);
        bool surgeAfter = hook.surgePending(pid);
        uint256 lastSwapBlockAfter = hook.lastSwapBlock(pid);

        console2.log("");
        console2.log("===== POST-SCENARIO STATE =====");
        console2.log("accruedFees[c0]   :", feesC0After);
        console2.log("accruedFees[c1]   :", feesC1After);
        console2.log("surgePending      :", surgeAfter);
        console2.log("lastSwapBlock     :", lastSwapBlockAfter);

        console2.log("");
        console2.log("===== DELTA =====");
        console2.log("protocol cut c0   :", feesC0After - feesC0Before);
        console2.log("expected by formula (FINAL_SWAP * 7000 * 1000 / 1e10):");
        uint256 expected = uint256(-FINAL_SWAP) * 7000 * 1000 / 10_000_000_000;
        console2.log("  expected        :", expected);

        require(feesC0After - feesC0Before == expected, "protocol cut mismatch");
        require(!surgeAfter, "surge should be consumed");
        console2.log("");
        console2.log("OK - surge fired and protocol fee accrued on-chain");
    }
}
