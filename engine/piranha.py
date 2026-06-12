"""
piranha.py — the sensing module.

Watches a JITShield-protected pool on a live network, assembles activity windows
from on-chain events + hook state, and scores each for JIT risk. It "smells the
shoal": when the pattern of a coordinated JIT appears, it raises a verdict.

Detection ONLY. Piranha reads the chain and produces a verdict. It does not place
orders, does not front-run, does not transact. The defensive action (arming the
hook's surge for a pool) is an authorized owner operation, out of scope for this
read-only sensor.

Scorer loading (the open-core seam):
    If `engine/_core_signal.py` exists and exposes `CoreScorer`, piranha uses it —
    this is the private, precise detector that closes GAP-1. It is gitignored and
    ships only on the operator's machine. Otherwise piranha falls back to the open
    `ReferenceScorer`. Same interface, same result shape; different precision.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from interface import Observation, ReferenceScorer, ShieldSignal  # noqa: E402
import chain  # noqa: E402

# Deployed JITShield on Sepolia (see DEPLOYMENTS.md). Override with --hook.
DEFAULT_HOOK = "0xca2f96f95c9E7a2109ecbD64bf80F7Cf77d86ac8"
DEFAULT_POOL = "0x467d6551c1ac498475b01dd23cd73ce9a61de3fae5e00455e696cc55d5522818"

# Event topic0 hashes (keccak of the signatures).
TOPIC_JIT_DETECTED = "0x1edfe30e92a5e7721b8743f2dead9394351fae11ebce15371ba1b58e556af436"
TOPIC_SURGE_APPLIED = "0x86290bd4a7943ce8ba2fe5bb36ed642bb30abb788a3d3c1f13115107714caab5"
TOPIC_FEE_ACCRUED = "0x7ed908ff2e40b254ea911b86a8497222ab54394e5961796285735f1e6306179d"

# Function selectors (first 4 bytes of keccak of the signature). Precomputed so the
# engine has no keccak dependency. Verified against the deployed hook ABI.
SELECTORS = {
    "lastSwapBlock(bytes32)": "0xe9702d27",
    "surgePending(bytes32)": "0x8a6a206d",
    "accruedFees(address)": "0x07311283",
    "surgeFeeBips()": "0x5fdefa2c",
}


def load_scorer():
    """Prefer the private CoreScorer; fall back to the open ReferenceScorer."""
    core_path = os.path.join(HERE, "_core_signal.py")
    if os.path.exists(core_path):
        try:
            from _core_signal import CoreScorer  # type: ignore
            return CoreScorer(), "core"
        except Exception as e:  # noqa: BLE001
            print(f"[piranha] core present but failed to load ({e}); using reference",
                  file=sys.stderr)
    return ReferenceScorer(), "reference"


def read_hook_state(hook, pool_id, url=None):
    """Read live hook state for a pool: lastSwapBlock + surgePending."""
    last_swap_data = SELECTORS["lastSwapBlock(bytes32)"] + chain.encode_bytes32(pool_id)
    surge_data = SELECTORS["surgePending(bytes32)"] + chain.encode_bytes32(pool_id)
    last_swap = chain.decode_uint(chain.eth_call(hook, last_swap_data, url=url))
    surge_raw = chain.decode_uint(chain.eth_call(hook, surge_data, url=url))
    return last_swap, bool(surge_raw)


def read_events(hook, from_block, to_block, url=None):
    """Pull JITShield events in a block range, newest activity surfaced as a list."""
    out = []
    for topic, kind in (
        (TOPIC_JIT_DETECTED, "jit_detected"),
        (TOPIC_SURGE_APPLIED, "surge_applied"),
        (TOPIC_FEE_ACCRUED, "fee_accrued"),
    ):
        try:
            logs = chain.get_logs(hook, [topic], from_block, to_block, url=url)
        except Exception:
            logs = []
        for lg in logs:
            out.append({
                "kind": kind,
                "block": int(lg.get("blockNumber", "0x0"), 16),
                "tx": lg.get("transactionHash"),
                "topics": lg.get("topics", []),
                "data": lg.get("data", "0x"),
            })
    out.sort(key=lambda e: e["block"])
    return out


def observe(hook, pool_id, lookback, url=None):
    """Assemble an Observation from live chain state + recent events."""
    head = chain.block_number(url=url)
    frm = max(head - lookback, 0)
    last_swap, surge_pending = read_hook_state(hook, pool_id, url=url)
    raw = read_events(hook, frm, head, url=url)

    # Translate hook events into the generic event stream the scorers consume.
    events = []
    for e in raw:
        if e["kind"] == "jit_detected":
            events.append(("add", e["block"], "flagged-lp", e["tx"]))
        elif e["kind"] == "surge_applied":
            events.append(("swap", e["block"], "surged-swap", e["tx"]))
    obs = Observation(
        pool_id=pool_id, block=head, events=events,
        last_swap_block=last_swap, surge_pending=surge_pending,
    )
    return obs, raw, head


def run(hook, pool_id, lookback, url=None, as_json=False):
    scorer, mode = load_scorer()
    obs, raw, head = observe(hook, pool_id, lookback, url=url)
    signal: ShieldSignal = scorer.score(obs)

    if as_json:
        print(json.dumps({
            "scorer": scorer.name, "mode": mode, "head": head,
            "hook": hook, "pool": pool_id,
            "last_swap_block": obs.last_swap_block,
            "surge_pending": obs.surge_pending,
            "events_seen": len(raw),
            "signal": signal.to_dict(),
        }, indent=2))
        return signal

    print(f"=== PIRANHA | live | scorer={scorer.name} ({mode}) ===")
    print(f"  head block      : {head}")
    print(f"  hook            : {hook}")
    print(f"  pool            : {pool_id[:18]}...")
    print(f"  lastSwapBlock   : {obs.last_swap_block}")
    print(f"  surgePending    : {obs.surge_pending}")
    print(f"  events (window) : {len(raw)}")
    print(f"  VERDICT         : {signal.verdict.upper()}  "
          f"score={signal.score:.2f}  pattern={signal.pattern}")
    print(f"  detail          : {signal.detail}")
    if mode == "reference":
        print("  note            : running OPEN reference scorer — add-first JIT (GAP-1)")
        print("                    is not covered. Precise core is private.")
    return signal


def main(argv=None):
    ap = argparse.ArgumentParser(description="JITShield Piranha — live JIT sensor (read-only)")
    ap.add_argument("--hook", default=DEFAULT_HOOK)
    ap.add_argument("--pool", default=DEFAULT_POOL)
    ap.add_argument("--lookback", type=int, default=5000, help="blocks of history to scan")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    run(args.hook, args.pool, args.lookback, as_json=args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
