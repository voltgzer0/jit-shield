# JITShield Security Review

This document is the project's own pre-deploy security review. It is **not** an external audit.
It records:

1. What was checked (tooling and manual scope).
2. Findings, with severity and current status.
3. The pre-mainnet checklist that must be cleared before holding real user funds.

Anyone evaluating whether to seed liquidity into a JITShield-protected pool should read this
end-to-end and then read [the contract](src/JITShield.sol) themselves.

---

## 1. Scope

- **Target**: `src/JITShield.sol` only. The v4-core / v4-periphery libraries are out of scope
  and assumed to behave as specified by Uniswap.
- **Tooling**: Slither 0.11.5 (`solc 0.8.26`, evm cancun), manual function-by-function review.
- **Tests**: 12 unit + integration + economics tests, all passing on each commit.

```
forge test  →  12 passed; 0 failed; 0 skipped
slither src/JITShield.sol --filter-paths lib/ --exclude-informational
  →  1 result (false positive — see F-INFO-1)
```

---

## 2. Findings

Severity scale: **CRITICAL** = direct loss of user funds, **HIGH** = loss of protocol funds or
governance compromise, **MEDIUM** = degraded UX / lost revenue / detection inaccuracy, **LOW** =
defence-in-depth gap with limited exposure, **INFO** = noted, no action.

### F-HIGH-1 — Owner is a single key

**Where**: `owner` storage, `onlyOwner` modifier (`src/JITShield.sol:55`, `:102`).

**Issue**: A compromised `owner` key can: (a) zero out `surgeFeeBips` to disable the protection
mechanism, (b) drain all `accruedFees` to an attacker via `withdrawProtocolFees`, (c) transfer
ownership away with no recovery. The owner cannot drain LP positions or pool reserves — those
are held by `PoolManager`, not the hook — but the protocol's entire revenue line and reputation
sit behind this one key.

**Status**: **OPEN — must be resolved before mainnet**.

**Fix**: Set the deployed `owner` to a multisig (Safe / Squad) or to a timelock-gated multisig.
Single EOA is acceptable only for testnet.

---

### F-MEDIUM-1 — Single-step `transferOwnership`

**Where**: `transferOwnership(address newOwner)` (`src/JITShield.sol:123`).

**Issue**: A typo in `newOwner` permanently transfers control to an unrecoverable address.
There is no on-chain ability to abort or rotate back.

**Status**: **OPEN**.

**Fix**: Move to a two-step (propose + accept) pattern, e.g. OpenZeppelin's `Ownable2Step`.
The current owner calls `proposeOwner(newOwner)`; the new owner calls `acceptOwnership()` to
take control. A typo never lands.

---

### F-MEDIUM-2 — JIT detection is same-block-only, no range-width signal

**Where**: `beforeAddLiquidity` (`src/JITShield.sol:153`).

**Issue**: The current heuristic flags _any_ liquidity added in the same block as the last swap
on that pool. In busy pools this catches not only JIT searchers but also (rare) legitimate LPs
who refill or migrate in active blocks. Such an LP gets time-locked from surge redistribution
for 5 blocks. They do **not** lose base v4 fees — only any surge premium that fires during the
lock window. The false-positive cost is therefore small but non-zero.

**Status**: **OPEN — quality-of-detection issue, not a security hole.**

**Fix**: Add a tick-range width threshold. JIT positions are by definition very tight (single
or low-double-digit tick width); honest passive LPs are usually wider. Suggested rule: flag
only if both same-block and `(tickUpper - tickLower) <= jitWidthThreshold`. Make
`jitWidthThreshold` configurable via `setConfig`.

---

### F-MEDIUM-3 — Exact-output swaps do not contribute protocol fee

**Where**: `beforeSwap` (`src/JITShield.sol:229`).

**Issue**: The protocol cut is only carved when `params.amountSpecified < 0` (exact-input
swap). Exact-output swaps still pay the surge LP fee — LPs are still protected — but the
protocol revenue line is zero for those swaps. This is lost revenue, not a vulnerability.

**Status**: **OPEN — revenue optimisation**.

**Fix**: For exact-output swaps, the input currency is the _unspecified_ side. Compute the cut
against the resulting `BalanceDelta` reported in `afterSwap` (where we know the realised input
amount) and call `poolManager.take` from a deferred-settle pattern there.

---

### F-MEDIUM-4 — No pause / emergency stop

**Where**: hook-wide.

**Issue**: If a vulnerability is discovered post-deploy there is no admin switch to halt
protocol-fee accrual or fall back to no-surge behaviour. The only mitigations are:
`setConfig(0,0,1)` to disable surge and protocol cut, and removing the hook by relaunching
pools without it.

**Status**: **OPEN**.

**Fix**: Add a `paused` flag. When set, `beforeSwap` skips both surge and cut and returns
zero delta + zero override. `beforeAddLiquidity` skips JIT detection. Only owner can toggle.

---

### F-MEDIUM-5 — `surgePending` is per-pool, not per-actor

**Where**: `beforeRemoveLiquidity` (`src/JITShield.sol:193`).

**Issue**: When a JIT searcher arms surge by removing during their lock window, the next
swapper on that pool pays the surge fee — even if they are completely unrelated to the JIT
activity. In practice the "next swap" usually _is_ the swap the JIT was front-running, but
not always. There is no formal binding between the surge arm and the targeted swap.

**Status**: **ACKNOWLEDGED, acceptable**.

**Rationale**: The whole point is to dilute the JIT searcher's economic gain by forcing them
to either (a) pay surge themselves on exit or (b) leak the surge to the targeted swapper. In
the rare case an unrelated trader is the next swapper, they pay 0.7% more than expected — bad
UX, but no loss of funds and no manipulability. Document on the LP-facing page.

---

### F-LOW-1 — Constructor previously did not validate `_poolManager != address(0)`

**Where**: `constructor` (`src/JITShield.sol:82`).

**Status**: **FIXED in this review** — added `if (address(_poolManager) == address(0)) revert
InvalidConfig();`.

---

### F-LOW-2 — `withdrawProtocolFees` previously did not validate `to != address(0)`

**Where**: `withdrawProtocolFees` (`src/JITShield.sol:273`).

**Status**: **FIXED in this review** — added `if (to == address(0)) revert InvalidConfig();`.

---

### F-LOW-3 — `transferOwnership` previously emitted no event

**Where**: `transferOwnership` (`src/JITShield.sol:123`).

**Status**: **FIXED in this review** — added `OwnershipTransferred(previous, newOwner)` event,
matching the OZ Ownable convention.

---

### F-LOW-4 — Reentrancy via `poolManager.take` token transfer

**Where**: `beforeSwap` (`src/JITShield.sol:242`).

**Issue (pre-fix)**: `accruedFees` was incremented after `poolManager.take`. If the input token
had a callback in its `transfer` (ERC777-style, custom token), it could re-enter JITShield.
Re-entering does little — the only external-facing state-changing functions are guarded by
`onlyPoolManager` or `onlyOwner` — but it violates Checks-Effects-Interactions.

**Status**: **FIXED in this review** — `accruedFees` increment and `returnDelta` set
moved before the external call.

---

### F-INFO-1 — Slither flags strict equality `lastSwapBlock[pid] == block.number`

**Where**: `beforeAddLiquidity` (`src/JITShield.sol:162`).

**Slither output**: `Detector: incorrect-equality`.

**Status**: **FALSE POSITIVE — by design**.

**Rationale**: Same-block JIT detection is _defined_ by `addLiquidity.block == lastSwap.block`.
Strict equality is the correct comparator here; relaxing to `<=` or `<` would either widen
detection to unrelated history or break the heuristic entirely.

---

### F-INFO-2 — Cut > `int128.max` is silently dropped

**Where**: `beforeSwap` (`src/JITShield.sol:233`).

**Status**: **ACKNOWLEDGED**.

**Rationale**: Trigger threshold is `swap_input > ~1.7e29` token-units (i.e. ~170 quintillion
tokens with 18 decimals). Not reachable in any realistic pool. Documented and tested via the
boundary in the existing unit tests.

---

### F-INFO-3 — Donate hooks are no-ops

**Where**: `beforeDonate`, `afterDonate`.

**Status**: **ACKNOWLEDGED**.

**Rationale**: Donation flow is orthogonal to JIT MEV. Implementing as no-ops keeps the IHooks
interface complete without expanding attack surface or hook permission bits.

---

## 3. Pre-mainnet checklist

Order from most to least blocking. Items not checked here block production deployment.

- [ ] **F-HIGH-1**: `owner` configured as Safe/Squad multisig, ideally behind a 24–48h
  timelock. EOA is forbidden for mainnet.
- [ ] **F-MEDIUM-1**: Two-step ownership transfer implemented.
- [ ] **F-MEDIUM-2**: Range-width threshold added to JIT detection. Tune by replaying
  historical mainnet JIT transactions.
- [ ] **F-MEDIUM-3**: Exact-output protocol cut path implemented + tested.
- [ ] **F-MEDIUM-4**: `paused` flag implemented with owner-only toggle and event log.
- [x] **F-LOW-1**: Constructor validates `_poolManager`.
- [x] **F-LOW-2**: `withdrawProtocolFees` validates `to`.
- [x] **F-LOW-3**: `OwnershipTransferred` event emitted.
- [x] **F-LOW-4**: Checks-effects-interactions ordering in `beforeSwap`.
- [ ] **External audit**: at minimum one independent firm (e.g. Spearbit / Trail of Bits /
  Zellic). Budget: ~$30–60k for a contract of this size and complexity.
- [ ] **Bug bounty**: Immunefi listing with ≥$50k payout for critical findings, active for at
  least 14 days before any pool with >$100k TVL is launched with this hook.
- [ ] **Slither in CI**: GitHub Actions runs `slither src/` on every PR; merge blocked on
  unsuppressed findings.
- [ ] **Mainnet-fork replay**: a fork test that replays the 5 highest-profit JIT transactions
  from the last 30 days against a JITShield-protected pool, demonstrating real-data
  protection.
- [ ] **Operational runbook**: documented procedures for incident response, owner key
  rotation, surge-config emergency tuning.

---

## 4. Out-of-scope notes

- v4-core and v4-periphery are trusted. A vulnerability in `PoolManager.take` /
  `PoolManager.unlock` / hook dispatching breaks JITShield and every other v4 hook.
- The CREATE2 deploy salt mining in `script/DeployJITShield.s.sol` is salt-deterministic on
  constructor args. An attacker who reuses the exact same args + bytecode at the same address
  produces a functionally identical contract — the field `owner` is part of the encoded args,
  so they cannot quietly seize control. They can only grief the deploy by burning gas.
- The hook intentionally does no slippage check, no oracle read, and no aggregate accounting.
  It is pure stateless-per-swap surge bookkeeping. This keeps gas low and the audit surface
  small.

---

## 5. Change log

- 2026-06-09: Initial review. Slither + manual. F-LOW-1..4 fixed in-line. F-MEDIUM-1..5 and
  F-HIGH-1 deferred to pre-mainnet milestone.
