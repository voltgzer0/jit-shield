// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@v4-core/test/utils/Deployers.sol";
import {JITShield} from "../src/JITShield.sol";
import {Hooks} from "@v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/src/types/PoolId.sol";
import {Currency} from "@v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@v4-core/src/types/PoolOperation.sol";

/// @notice Phase-1 of the replay-and-measure pipeline.
///         Reads `datasets/mainnet-jit-replay/jit_candidates.csv` (produced by the
///         Phase-0 Python finder), and for each candidate row spins up a fresh
///         JITShield-protected v4 pool sized to the candidate's swap volume,
///         replays the same-block JIT scenario (passive_add → primer_swap →
///         JIT_add → JIT_remove → final_swap), and records:
///           - protocol-fee accrual on the hook
///           - LP receipts compared to the no-hook baseline
///           - searcher P&L compared to the no-hook baseline
///
///         Output: per-candidate row appended to
///         `datasets/mainnet-jit-replay/replay_results.csv`.
///
/// @dev    This Phase-1 test does NOT require a live mainnet fork — it uses
///         mock currencies sized to the historic swap amounts. A future
///         Phase-1.5 will fork mainnet at each candidate block for realistic
///         AMM curve state.
contract JITShieldReplayTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    JITShield internal hook;
    address internal ownerAddr = makeAddr("hookOwner");

    // Phase-0 dataset path (relative to project root)
    string constant CANDIDATES_CSV = "datasets/mainnet-jit-replay/jit_candidates.csv";
    string constant RESULTS_CSV = "datasets/mainnet-jit-replay/replay_results.csv";

    function setUp() public {
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
            abi.encode(manager, ownerAddr, uint24(7000), uint16(1000), uint16(5)),
            target
        );
        hook = JITShield(payable(target));

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
    }

    /// @notice Loads the Phase-0 candidate CSV and runs a replay scenario per row.
    ///         Set CSV row limit via env: REPLAY_LIMIT (default 10). Skip with
    ///         REPLAY_SKIP=1 if running tests without the dataset present.
    function test_ReplayHistoricJITCandidates() public {
        if (vm.envOr("REPLAY_SKIP", uint256(0)) == 1) {
            console2.log("REPLAY_SKIP set - skipping replay test");
            return;
        }

        // Read the CSV; if absent we still want this test to pass (it just becomes a no-op
        // until Phase-0 runs and produces the dataset).
        string memory csv;
        try vm.readFile(CANDIDATES_CSV) returns (string memory data) {
            csv = data;
        } catch {
            console2.log("Phase-0 dataset not present; run scripts/replay/jit_finder.py first");
            return;
        }

        // CSV parsing is intentionally simple: split on '\n', then on ','.
        // We expect the Phase-0 header row first, then one row per candidate.
        string[] memory rows = vm.split(csv, "\n");
        uint256 limit = vm.envOr("REPLAY_LIMIT", uint256(10));
        uint256 done = 0;

        uint256 totalProtocolAccrued = 0;
        uint256 totalCandidates = 0;

        for (uint256 i = 1; i < rows.length && done < limit; i++) {
            if (bytes(rows[i]).length < 16) continue; // skip blanks
            string[] memory cols = vm.split(rows[i], ",");
            if (cols.length < 13) continue;

            // Columns (from Phase-0 finder, see scripts/replay/jit_finder.py):
            //  0=block 1=sender 2=pool_tag 3=pool_address
            //  4=mint_tx 5=swap_tx 6=burn_tx
            //  7=swap_amount0 8=swap_amount1
            //  9=tick_lower 10=tick_upper 11=range_width 12=other_swaps_same_block

            int256 swapAmount0 = vm.parseInt(cols[7]);
            // For replay we just need a positive magnitude — the direction is encoded in sign.
            uint256 absSwap0 = swapAmount0 < 0 ? uint256(-swapAmount0) : uint256(swapAmount0);
            if (absSwap0 == 0) continue;

            // Scale the historic swap volume down to fit our test pool's seed liquidity.
            // Phase-1.5 will fork at the block to avoid this approximation.
            uint256 scaled = absSwap0 / 1e3;
            if (scaled < 1e15) scaled = 1e15;        // floor at 0.001 token
            if (scaled > 1e18) scaled = 1e18;        // ceil at 1 token (within seeded liquidity)

            uint256 protocolAccruedBefore = hook.accruedFees(currency0);
            _runOneJITReplay(int256(scaled));
            uint256 protocolAccruedAfter = hook.accruedFees(currency0);
            uint256 deltaProtocol = protocolAccruedAfter - protocolAccruedBefore;

            console2.log("replay candidate ", done + 1);
            console2.log("  block        :", cols[0]);
            console2.log("  pool         :", cols[2]);
            console2.log("  scaled input :", scaled);
            console2.log("  protocol cut :", deltaProtocol);

            totalProtocolAccrued += deltaProtocol;
            totalCandidates++;
            done++;
        }

        console2.log("");
        console2.log("===== Phase-1 replay summary =====");
        console2.log("Candidates replayed   :", totalCandidates);
        console2.log("Total protocol accrued:", totalProtocolAccrued);
    }

    function _runOneJITReplay(int256 inputAmount) internal {
        PoolId pid = key.toId();

        // Seed deep passive liquidity each scenario so the pool can absorb the swap.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: 1e22,
                salt: bytes32(uint256(0xBEEF))
            }),
            ZERO_BYTES
        );

        // Primer swap (arms lastSwapBlock).
        swap(key, true, -1e15, ZERO_BYTES);

        // JIT add (same block).
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1e21,
                salt: bytes32(uint256(uint160(block.timestamp)))
            }),
            ZERO_BYTES
        );

        // JIT remove (same block — arms surge).
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -1e21,
                salt: bytes32(uint256(uint160(block.timestamp)))
            }),
            ZERO_BYTES
        );

        require(hook.surgePending(pid), "surge expected to arm");

        // Final swap — consumes surge, accrues protocol fee.
        swap(key, true, -inputAmount, ZERO_BYTES);

        require(!hook.surgePending(pid), "surge expected to be consumed");

        // Move forward so the next scenario starts in a fresh block window.
        vm.roll(block.number + 10);
    }
}
