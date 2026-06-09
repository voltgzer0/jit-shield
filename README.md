# JITShield

A Uniswap v4 hook that neutralises Just-In-Time (JIT) MEV against passive LPs and earns a
protocol fee on every shielded swap.

- 🌐 **Live site:** [voltgzer0.github.io/jit-shield](https://voltgzer0.github.io/jit-shield)
- 📜 **Hook on Sepolia (verified):** [`0xca2f96f95c9E7a2109ecbD64bf80F7Cf77d86ac8`](https://sepolia.etherscan.io/address/0xca2f96f95c9E7a2109ecbD64bf80F7Cf77d86ac8#code)
- ✅ **Tests:** 12 / 12 passing · Slither: 0 actionable findings
- 🔐 **Audit posture:** see [`SECURITY.md`](./SECURITY.md)
- 📦 **All deployments and tx hashes:** see [`DEPLOYMENTS.md`](./DEPLOYMENTS.md)

## The problem

Uniswap v3 and v4 LPs lose an estimated **$50–200M per year** to JIT liquidity strategies.
A searcher watches the mempool, spots a large swap, adds a huge tight-range position in the
same block right before that swap, captures ~80% of its fees, and removes the position in
the same block. Passive LPs who provide liquidity 24/7 take the leftovers.

## The mechanism

JITShield runs three coordinated rules inside a v4 pool with a dynamic LP fee:

1. **Same-block detection** — `beforeAddLiquidity` flags any position added in the same
   block as the previous swap and time-locks it for `timeLockBlocks` blocks. Time-locked
   positions are excluded from receiving any surge premium that gets redistributed.
2. **Surge fee** — when a flagged position is removed while still inside its lock window,
   the next swap on that pool is charged an additional `surgeFeeBips` fee (returned via
   `beforeSwap` as a dynamic-fee override). The surge premium goes to passive LPs.
3. **Protocol fee** — a `protocolFeeBips` slice of the surge premium is carved out via
   `BeforeSwapDelta` and pulled into the hook contract through `PoolManager.take`. This
   is JITShield's revenue line.

## Revenue model

Per shielded swap (verified by formula and by the live Sepolia test):

- Surge premium = `input * 0.7%`
- LP share     = 90% of premium
- **Protocol cut = 10% of premium = 700 ppm of input**

Scaled to a single $500K shielded swap: $3,150 to passive LPs, $350 to the protocol.

Annualised projection at 10 shielded swaps/day per pool: ~$1.27M protocol ARR per pool.
First-year realistic ARR with 1–3 partner pools at lower throughput: **$100K–500K range.**
Zero pools adopt = zero revenue. This is honest software-as-a-public-good economics.

## Live on Sepolia — end-to-end proof

| What | Where |
|---|---|
| Hook contract (verified source) | [`0xca2f96f95c9…77d86ac8`](https://sepolia.etherscan.io/address/0xca2f96f95c9E7a2109ecbD64bf80F7Cf77d86ac8#code) |
| Bound PoolManager | [`0xE03A1074…E203543`](https://sepolia.etherscan.io/address/0xE03A1074c86CFeDd5C142C4F04F1a1536e203543) |
| Live test pool (init tx) | [`0x4198bd4f…e7546b`](https://sepolia.etherscan.io/tx/0x4198bd4f0ca2723e0f9632bbc708a4af8e53ccde5c46e398f6092d320ee7546b) |
| Live JIT scenario (one atomic tx) | [`0x2ee624d8…a1d1f`](https://sepolia.etherscan.io/tx/0x2ee624d85aa911c9a7d54a975266b77f7cb8a75810d312c963b791e8f35a1d1f) |
| Protocol fee accrued on chain | `7×10¹⁴ wei` of currency0 — physically held by the hook |

Anyone can re-verify in 5 seconds from a public RPC:

```bash
cast call 0xca2f96f95c9E7a2109ecbD64bf80F7Cf77d86ac8 \
    'accruedFees(address)(uint256)' \
    0x7CE8535D4fD28DE2d929B03A7B6d9d6045F36872 \
    --rpc-url https://ethereum-sepolia.publicnode.com
# → 700000000000000
```

## Status

- [x] Foundry project against v4-periphery (with v4-core as a transitive dep)
- [x] `IHooks`-implementing contract with full lifecycle hooks
- [x] Unit + integration + economics test suites (12 / 12 passing)
- [x] CREATE2 salt-mined deploy hitting the required flag-bit address
- [x] Protocol-fee settlement via `PoolManager.take` inside the v4 unlock callback
- [x] **Sepolia deploy + dynamic-fee pool initialisation + verified on Etherscan**
- [x] **Live JIT scenario executed on Sepolia, protocol fee accrued on chain**
- [x] Slither + manual self-review (4 LOW findings fixed, others tracked)
- [ ] External audit (Spearbit / ToB / Zellic) — required before mainnet
- [ ] Immunefi bug bounty open ≥ 14 days before any pool with > $100k TVL
- [ ] Base / Ethereum mainnet deploy with partner pool

## Build & test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
forge build
forge test -vv
```

Specific suites:

```bash
forge test --match-contract JITShieldTest -vv             # unit tests
forge test --match-contract JITShieldIntegrationTest -vv  # end-to-end vs PoolManager
forge test --match-contract JITShieldEconomicsTest  -vv   # economics demo
```

## Layout

```
src/JITShield.sol                              # the hook
script/DeployJITShield.s.sol                   # CREATE2 salt-mined deploy
script/InitPoolSepolia.s.sol                   # create pool + seed liquidity
script/JITSimulateSepolia.s.sol                # run live JIT scenario on chain
script/utils/JITSimulator.sol                  # testnet IUnlockCallback helper
test/JITShield.t.sol                           # unit tests
test/JITShieldIntegration.t.sol                # end-to-end on PoolManager
test/JITShieldEconomics.t.sol                  # ppm + USD projection
docs/index.html                                # landing page (served by GitHub Pages)
DEPLOYMENTS.md                                 # all deployed addresses + tx hashes
SECURITY.md                                    # self-audit + pre-mainnet checklist
```

## Author

Built by [voltgzer0](https://github.com/voltgzer0) · `voltmattty77@gmail.com`

Whitehat. Bug-bounty friendly. Open to partner pools.

## License

MIT — see [`LICENSE`](./LICENSE).
