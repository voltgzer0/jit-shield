# JITShield

A Uniswap v4 hook that protects passive liquidity providers from Just-In-Time (JIT) MEV
extraction, and earns a protocol fee on every swap it shields.

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
3. **Protocol fee** — a `protocolFeeBips` slice of the surge premium is retained by the
   hook contract as its sustainability fee. This is JITShield's revenue line.

## Revenue model

For a pool with $5M TVL and $20M daily volume:

- ~15% of volume is JIT-shaped flow → $3M/day
- Surge premium at 0.7% on shaped flow → $21k/day to passive LPs
- Hook fee at 10% of that premium → **~$2.1k/day per pool** to the project

A handful of mid-size pools at ~$5M TVL is enough to make this self-sustaining. Zero pools
adopt = zero revenue; this is honest software-as-a-public-good economics.

## Status

- [x] Foundry project scaffolded against v4-periphery (which transitively pulls v4-core)
- [x] Hook contract `src/JITShield.sol` implementing `IHooks`
- [x] Unit tests for access control, JIT detection, surge flow (8/8 passing)
- [ ] Mainnet-fork integration test against a real `PoolManager` deployment
- [ ] CREATE2 address-mining script so the deployed address carries the correct hook
      permission bits in its low-order 14 bits
- [ ] Protocol-fee settlement via `PoolManager.take()` inside the v4 unlock callback
- [ ] Sepolia testnet deploy + dynamic-fee pool initialisation
- [ ] Slither + manual review
- [ ] Base mainnet deploy with one partner pool

## Build & test

Requires Foundry. Inside WSL:

```bash
export PATH="$PATH:$HOME/.foundry/bin"
cd /mnt/d/ZEROO1/TOWER/jit-shield
forge build
forge test -vv
```

## Layout

```
src/JITShield.sol           # the hook
test/JITShield.t.sol        # unit tests
lib/forge-std/              # Forge std library
lib/v4-periphery/           # Uniswap v4 periphery + nested v4-core
remappings.txt              # @v4-core/, @v4-periphery/, forge-std/
foundry.toml                # solc 0.8.26, cancun, optimizer on
```

## License

MIT.
