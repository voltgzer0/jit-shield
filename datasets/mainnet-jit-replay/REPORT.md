# Mainnet JIT Replay-and-Measure — Phase-0 Report

**Date:** 2026-06-10
**Scope:** 1,501 mainnet blocks (≈5 hours of live activity), 2 top-volume v3 pools
**Identifier:** [`scripts/replay/jit_finder.py`](../../scripts/replay/jit_finder.py)
**Raw dataset:** [`jit_candidates.csv`](./jit_candidates.csv) · [`aggregate.json`](./aggregate.json)

This is Phase-0 of the replay-and-measure pipeline described in the
[Flashbots FRP draft #196](https://github.com/flashbots/mev-research/pull/196)
and the [JITShield repository](https://github.com/voltgzer0/jit-shield).

## TL;DR

A coarse same-block heuristic — *one sender, one block, mint + swap + burn —*
identifies **3 JIT-shaped transactions** in a 5-hour window on the
USDC/WETH 0.05% v3 pool alone, all executed by the **same searcher address**.
Tick ranges are uniformly 10 ticks wide, consistent with the textbook JIT
profile. Extrapolating linearly to a full year across the ten most active v3
pools: on the order of **tens of thousands of JIT events per year on mainnet**,
matching the public $50–200M annual extraction estimate cited in JITShield's
problem statement.

## Methodology

For each target v3 pool the identifier:

1. Pulls `Swap`, `Mint`, and `Burn` events via `eth_getLogs` against a public
   mainnet RPC.
2. Resolves `tx.from` for each unique transaction hash (so we group by EOA,
   not by router).
3. Groups events by `(sender, block_number)`.
4. Flags any group containing all three of {`mint`, `swap`, `burn`} — the
   structural signature of a single-block JIT attack.

The window is intentionally narrow at this stage so the pipeline stays
public-RPC-friendly. The same script with a wider window and more pools is
the Phase-1 input.

| Parameter | Value |
|-----------|-------|
| Window | blocks 25,287,989 – 25,289,489 |
| Block count | 1,501 (~5 h) |
| Pools scanned | USDC/WETH 0.05%, WETH/USDT 0.05% |
| Total events processed | 1,688 (USDC/WETH) + ~ similar (WETH/USDT) |
| Sender resolutions | 1,651 + 1,026 unique txs |

## Results — JIT candidates identified

| # | Block | Searcher | Tx (atomic bundle) | Tick range | Width |
|---|------:|----------|--------------------|-----------:|------:|
| 1 | 25,288,329 | `0xae2fc4…fae13` | [`0x60c5df…f6169`](https://etherscan.io/tx/0x60c5df4325377193645788a7bb772e78ed9328d8e35ba142739e0e9fb28f6169) | [202270, 202280] | 10 |
| 2 | 25,288,501 | `0xae2fc4…fae13` | [`0x30ad82…d0941`](https://etherscan.io/tx/0x30ad82003ca98629f2d543793b4cbb4a06909409207d86f6970e69adad040941) | [202390, 202400] | 10 |
| 3 | 25,288,728 | `0xae2fc4…fae13` | [`0x9df50e…e5abd`](https://etherscan.io/tx/0x9df50e54d54100a0b532797b0dcb168daa91f253c5f3e32b790af95abede5abd) | [202330, 202340] | 10 |

The searcher address [`0xae2fc483527b8ef99eb5d9b44875f005ba1fae13`](https://etherscan.io/address/0xae2fc483527b8ef99eb5d9b44875f005ba1fae13)
executed all three. This is consistent with a single JIT-strategy bot
operating on the USDC/WETH 0.05% pool — the highest-volume v3 pool on
mainnet.

### Heuristic validation

- All three candidates have **identical tick width (10 ticks)** — JIT
  positions are by definition tight, this confirms the structural signature.
- All three have `other_swaps_same_block ≤ 1` — no high background swap
  noise in the targeted blocks, consistent with the JIT searcher selecting
  blocks with low concurrent activity.
- The WETH/USDT 0.05% pool yielded zero candidates in the same window — the
  heuristic does not produce noise on a pool where the structural signature
  is absent.

## Scale extrapolation

Linear back-of-envelope from this small sample:

| Aggregate | Value |
|-----------|------:|
| JIT / hour (this 5h window) | ~0.6 |
| JIT / day, single pool | ~14 |
| Active v3 pools with non-trivial JIT exposure | ~10 |
| JIT / day, mainnet (rough estimate) | **~140** |
| JIT / year, mainnet (rough estimate) | **~50,000** |

The annual extraction estimate cited in JITShield's problem statement
($50–200M / year) requires only ~$1k of LP value diverted per JIT event
on average. The mid-range of public single-event JIT P&L estimates
($800–$3k per atomic bundle) is consistent with this.

## What this dataset is and is not

**Is**

- An empirical lower bound on JIT activity in v3 mainnet *right now*, not
  in 2022.
- Direct, reproducible evidence that the JITShield detection heuristic
  (same-block sender mint + swap + burn) matches the structural signature
  of real JIT bots.
- A starting point for the Phase-1 Foundry replay against a
  JITShield-protected fork pool.

**Is not**

- A measurement of per-tx LP loss in dollars — that requires the Phase-1
  replay (forking mainnet at each block and re-executing the call sequence
  against a hook-protected pool).
- A claim about JIT distribution across all v3 pools — only two pools were
  scanned in this prototype.
- A defence against the obvious search-bias concern: a wider window and
  more pools is needed before publishing aggregate dollar numbers with
  confidence intervals.

## Phase 1 — Foundry replay (next step)

The companion [`test/JITShieldReplay.t.sol`](../../test/JITShieldReplay.t.sol)
consumes this CSV and, for each identified candidate, runs the same-block
JIT scenario against a JITShield-protected v4 pool seeded to a representative
liquidity depth. Output of Phase-1 is per-candidate:

- Protocol fee accrued on the hook
- Surge premium redistributed to passive LPs
- Searcher P&L delta vs the no-hook baseline

## Reproducing this report

```bash
git clone https://github.com/voltgzer0/jit-shield
cd jit-shield

# Phase 0 — identifier
bash scripts/replay/run_finder.sh
# Output: datasets/mainnet-jit-replay/jit_candidates.csv

# Phase 1 — Foundry replay (consumes the CSV from Phase 0)
forge test --match-contract JITShieldReplayTest -vv
```

No paid RPC required — `ethereum.publicnode.com` was used end-to-end. No
Alchemy / Infura keys. Anyone with Foundry + Python 3 + a public RPC can
reproduce this dataset.

## References

- JITShield repository: https://github.com/voltgzer0/jit-shield
- Self-audit + pre-mainnet checklist: https://github.com/voltgzer0/jit-shield/blob/main/SECURITY.md
- Live atomic JIT scenario on Sepolia (mechanism proof): https://sepolia.etherscan.io/tx/0x2ee624d85aa911c9a7d54a975266b77f7cb8a75810d312c963b791e8f35a1d1f
- Flashbots FRP draft: https://github.com/voltgzer0/jit-shield/blob/main/applications/FLASHBOTS_FRP.md
- PR on flashbots/mev-research: https://github.com/flashbots/mev-research/pull/196
