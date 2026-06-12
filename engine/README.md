# JITShield Engine — Piranha & Reaper

Off-chain companions to the on-chain hook. Read-only, stdlib-only Python. No keys
to run the public path (defaults to a public Sepolia RPC).

```
piranha  →  senses JIT risk on a live pool   (detection)
reaper   →  reconciles protocol fees to the bone (settlement proof)
```

## Why an off-chain engine at all

The on-chain hook proves what the chain can prove: **same-block sandwich JIT**. It
**cannot** see classical **add-first JIT** (ADD → SWAP → REMOVE, add first in the
block) — at add-time there is no prior on-chain signal. That is the documented
[GAP-1](../test/JITShieldKnownLimitations.t.sol).

The engine closes that gap off-chain, where the signal exists.

## Open core

This directory is intentionally split:

| Part | Status | What it is |
|---|---|---|
| `interface.py` | **public** | result shape (`ShieldSignal`) + the open `ReferenceScorer` |
| `chain.py` | **public** | read-only JSON-RPC (block, call, logs) |
| `piranha.py` | **public** | live sensor; loads the precise scorer if present, else reference |
| `reaper.py` | **public** | fee reconciliation (`accrued == balance` proof) |
| `_core_signal.py` | **private** | the precise add-first detector — gitignored, not published |

The reference scorer is correct but limited — it reproduces only the on-chain
heuristic. The precise `CoreScorer` that closes GAP-1 lives off-repo on the
operator's machine. `piranha` runs either way: with the core it is full, without
it, half-full. The **verdict it emits is public and verifiable on-chain**; the
**method that produces the precise verdict is not**.

> A jug half-empty is not yet a jug. Filled, it becomes exactly the vessel it was
> shaped to be. The public engine is the vessel; the private core is the water.

If you see `reference` mode and think "this misses cases" — it does, on purpose.
The complete behaviour is real and runs live; the fragment that completes it is
available privately.

## Run (live, no setup)

```bash
# live JIT readout against the deployed Sepolia hook + pool
python3 engine/piranha.py

# live protocol-fee reconciliation (bookkeeping vs real ERC20 balance)
python3 engine/reaper.py

# machine-readable
python3 engine/piranha.py --json
python3 engine/reaper.py --json
```

Point at any pool/hook/network:

```bash
RPC_URL=https://your-node python3 engine/piranha.py \
  --hook 0x... --pool 0x... --lookback 20000
```

## Tests

```bash
python3 engine/tests/test_interface.py
python3 engine/tests/test_piranha.py
python3 engine/tests/test_reaper.py
```

Offline, mocked RPC. They exercise the public path only — the private core ships
with its own local tests on the operator's machine.

## Boundaries

Detection and accounting only. The engine never signs, never sends a transaction,
never front-runs. Arming the hook's surge and withdrawing fees are authorized
on-chain owner actions, performed elsewhere — not by this engine.
