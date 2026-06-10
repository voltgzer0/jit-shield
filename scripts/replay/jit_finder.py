#!/usr/bin/env python3
"""
JIT pattern finder — Phase 0 of replay-and-measure.

For each target v3 mainnet pool, this script:
  1. Pulls recent NonfungiblePositionManager (NPM) liquidity events for the pool.
  2. Pulls swap events on the pool for the same block range.
  3. Joins events by (sender, block_number) and flags any (sender, block) that has
     all three of: mint/increase liquidity, swap, burn/decrease liquidity — the
     classic same-block JIT signature.
  4. For each hit it records the swap input size, the position's tick range, and
     the sender's net token-flow inside that block (gas-only approximation; the
     full P&L requires re-pricing).
  5. Outputs:
        datasets/mainnet-jit-replay/jit_candidates.csv
        datasets/mainnet-jit-replay/aggregate.json

We do NOT use Alchemy/Infura here. Only a public RPC and Etherscan API (free
tier, voltmattty77@gmail.com key already in .env.testnet for the verify pipeline).

NOTE: this is a Phase-0 heuristic identifier. It is *coarse* by design — false
positives are accepted at this stage. Phase 1 (Foundry replay) is the rigorous
side that produces the final per-tx P&L.
"""

from __future__ import annotations

import csv
import json
import os
import sys
import time
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

import requests

# ---------- config ----------

# Top-volume v3 pools known to attract JIT. (poolAddress, fee_bps, tag)
# Phase-0 prototype: limit to 2 pools and a smaller window so the public RPC
# completes in minutes, not tens of minutes. Expand later.
TARGET_POOLS: list[tuple[str, int, str]] = [
    ("0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640", 500, "USDC/WETH 0.05%"),
    ("0x11b815efB8f581194ae79006d24E0d814B7697F6", 500, "WETH/USDT 0.05%"),
]

# Uniswap v3 NonfungiblePositionManager (mainnet) — for mint/burn events scoped to a pool.
NPM_ADDRESS = "0xC36442b4a4522E871399CD717aBDD847Ab11FE88"

# Latest block window (Phase 0 prototype — 1500 blocks ≈ 5h, public RPC friendly)
BLOCK_WINDOW = 1500

# Event signatures
SIG_SWAP = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"      # Pool.Swap(...)
SIG_MINT = "0x7a53080ba414158be7ec69b987b5fb7d07dee101fe85488f0853ae16239d0bde"      # Pool.Mint(...)
SIG_BURN = "0x0c396cd989a39f4459b5fa1aed6a9a8dcdbc45908acfd67e028cd568da98982c"      # Pool.Burn(...)

# RPC + Etherscan
PUBLIC_RPC = "https://ethereum.publicnode.com"
ETHERSCAN = "https://api.etherscan.io/api"

OUT_DIR = Path(__file__).resolve().parents[2] / "datasets" / "mainnet-jit-replay"


# ---------- types ----------

@dataclass
class PoolEvent:
    block: int
    tx_hash: str
    log_index: int
    sender: str            # tx-level msg.sender (router for swaps; positionManager for mint/burn)
    raw_event: str         # "swap" | "mint" | "burn"
    pool_address: str
    pool_tag: str
    amount0: int = 0       # signed; positive = into pool
    amount1: int = 0
    tick_lower: int = 0    # only for mint/burn
    tick_upper: int = 0

    @property
    def key(self) -> tuple[int, str]:
        # Group by (block, sender)
        return (self.block, self.sender.lower())


@dataclass
class JITCandidate:
    block: int
    sender: str
    pool_address: str
    pool_tag: str
    mint_tx: str = ""
    swap_tx: str = ""
    burn_tx: str = ""
    swap_amount0: int = 0
    swap_amount1: int = 0
    range_ticks: tuple[int, int] = (0, 0)
    range_width: int = 0
    other_swaps_same_block: int = 0


# ---------- rpc / etherscan helpers ----------

def get_latest_block(rpc: str) -> int:
    r = requests.post(rpc, json={"jsonrpc": "2.0", "method": "eth_blockNumber", "params": [], "id": 1}, timeout=15)
    r.raise_for_status()
    return int(r.json()["result"], 16)


def fetch_logs(rpc: str, address: str, topics: list[str | None], from_block: int, to_block: int) -> list[dict]:
    """eth_getLogs against the public node. Public nodes typically cap responses at
    ~1000 logs and ~500-block ranges — we chunk accordingly."""
    out: list[dict] = []
    step = 500
    cur = from_block
    while cur <= to_block:
        end = min(cur + step - 1, to_block)
        req = {
            "jsonrpc": "2.0",
            "method": "eth_getLogs",
            "params": [{
                "address": address,
                "fromBlock": hex(cur),
                "toBlock": hex(end),
                "topics": topics,
            }],
            "id": 1,
        }
        for attempt in range(3):
            try:
                r = requests.post(rpc, json=req, timeout=30)
                r.raise_for_status()
                payload = r.json()
                if "error" in payload:
                    # public RPC sometimes returns "query returned too many results"
                    # → split the range
                    if "too many results" in payload["error"].get("message", "").lower() or "limit" in payload["error"].get("message", "").lower():
                        if step > 50:
                            step = max(50, step // 2)
                            continue
                    raise RuntimeError(payload["error"])
                out.extend(payload["result"])
                break
            except Exception as exc:
                if attempt == 2:
                    raise
                time.sleep(1 + attempt)
        cur = end + 1
        # be polite to the public RPC
        time.sleep(0.1)
    return out


def fetch_tx_sender(rpc: str, tx_hash: str) -> str:
    r = requests.post(rpc, json={
        "jsonrpc": "2.0",
        "method": "eth_getTransactionByHash",
        "params": [tx_hash],
        "id": 1,
    }, timeout=15)
    r.raise_for_status()
    j = r.json().get("result")
    if not j:
        return ""
    return j["from"]


# ---------- event parsing ----------

def parse_signed_int256(hex32: str) -> int:
    """Decode a 32-byte two's-complement signed integer."""
    n = int(hex32, 16)
    if n >= 1 << 255:
        n -= 1 << 256
    return n


def parse_signed_int24(hex32: str) -> int:
    """24-bit signed int packed into 32 bytes."""
    n = int(hex32, 16)
    if n >= 1 << 23:
        n -= 1 << 24
    return n


def parse_swap_log(log: dict, pool_address: str, pool_tag: str) -> PoolEvent:
    # Swap(address sender, address recipient, int256 amount0, int256 amount1,
    #      uint160 sqrtPriceX96, uint128 liquidity, int24 tick)
    data = log["data"][2:]
    chunks = [data[i:i+64] for i in range(0, len(data), 64)]
    amount0 = parse_signed_int256(chunks[0])
    amount1 = parse_signed_int256(chunks[1])
    return PoolEvent(
        block=int(log["blockNumber"], 16),
        tx_hash=log["transactionHash"],
        log_index=int(log["logIndex"], 16),
        sender="",   # we'll fetch tx.from later
        raw_event="swap",
        pool_address=pool_address,
        pool_tag=pool_tag,
        amount0=amount0,
        amount1=amount1,
    )


def parse_mint_burn_log(log: dict, pool_address: str, pool_tag: str, kind: str) -> PoolEvent:
    # Mint(address sender, address owner indexed, int24 tickLower indexed, int24 tickUpper indexed,
    #      uint128 amount, uint256 amount0, uint256 amount1)
    # Burn(address owner indexed, int24 tickLower indexed, int24 tickUpper indexed,
    #      uint128 amount, uint256 amount0, uint256 amount1)
    topics = log["topics"]
    tick_lower = parse_signed_int24(topics[-2] if kind == "burn" else topics[-2])
    tick_upper = parse_signed_int24(topics[-1])
    data = log["data"][2:]
    chunks = [data[i:i+64] for i in range(0, len(data), 64)]
    # the last two uint256s are amount0, amount1
    amount0 = int(chunks[-2], 16)
    amount1 = int(chunks[-1], 16)
    return PoolEvent(
        block=int(log["blockNumber"], 16),
        tx_hash=log["transactionHash"],
        log_index=int(log["logIndex"], 16),
        sender="",
        raw_event=kind,
        pool_address=pool_address,
        pool_tag=pool_tag,
        amount0=amount0,
        amount1=amount1,
        tick_lower=tick_lower,
        tick_upper=tick_upper,
    )


# ---------- main correlation logic ----------

def gather_pool_events(rpc: str, pool: tuple[str, int, str], from_block: int, to_block: int) -> list[PoolEvent]:
    pool_address, _fee, pool_tag = pool
    print(f"[{pool_tag}] fetching logs {from_block}..{to_block}", file=sys.stderr)

    swap_logs = fetch_logs(rpc, pool_address, [SIG_SWAP], from_block, to_block)
    mint_logs = fetch_logs(rpc, pool_address, [SIG_MINT], from_block, to_block)
    burn_logs = fetch_logs(rpc, pool_address, [SIG_BURN], from_block, to_block)

    events: list[PoolEvent] = []
    for lg in swap_logs:
        events.append(parse_swap_log(lg, pool_address, pool_tag))
    for lg in mint_logs:
        events.append(parse_mint_burn_log(lg, pool_address, pool_tag, "mint"))
    for lg in burn_logs:
        events.append(parse_mint_burn_log(lg, pool_address, pool_tag, "burn"))

    # Resolve tx.from for each unique tx hash → that's our "sender" for grouping.
    unique_tx = {ev.tx_hash for ev in events}
    print(f"[{pool_tag}] resolving sender for {len(unique_tx)} unique txs", file=sys.stderr)
    tx_sender: dict[str, str] = {}
    for tx in unique_tx:
        tx_sender[tx] = fetch_tx_sender(rpc, tx)
        time.sleep(0.05)

    for ev in events:
        ev.sender = tx_sender.get(ev.tx_hash, "")

    return events


def find_jit_candidates(events: Iterable[PoolEvent]) -> list[JITCandidate]:
    """Find (sender, block) groups that contain at least one mint, swap, and burn."""
    grouped: dict[tuple[int, str], list[PoolEvent]] = defaultdict(list)
    for ev in events:
        if not ev.sender:
            continue
        grouped[ev.key].append(ev)

    candidates: list[JITCandidate] = []
    for (block, sender), evs in grouped.items():
        kinds = {ev.raw_event for ev in evs}
        if not {"mint", "swap", "burn"}.issubset(kinds):
            continue

        mint = next(e for e in evs if e.raw_event == "mint")
        swap = next(e for e in evs if e.raw_event == "swap")
        burn = next(e for e in evs if e.raw_event == "burn")

        width = burn.tick_upper - burn.tick_lower

        # Count other swaps in same block (likely the swap the JIT targeted)
        other_swaps = sum(
            1 for ev in evs if ev.raw_event == "swap" and ev.log_index != swap.log_index
        )

        candidates.append(JITCandidate(
            block=block,
            sender=sender,
            pool_address=mint.pool_address,
            pool_tag=mint.pool_tag,
            mint_tx=mint.tx_hash,
            swap_tx=swap.tx_hash,
            burn_tx=burn.tx_hash,
            swap_amount0=swap.amount0,
            swap_amount1=swap.amount1,
            range_ticks=(burn.tick_lower, burn.tick_upper),
            range_width=width,
            other_swaps_same_block=other_swaps,
        ))

    candidates.sort(key=lambda c: c.block)
    return candidates


# ---------- output ----------

def write_outputs(candidates: list[JITCandidate], from_block: int, to_block: int) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    csv_path = OUT_DIR / "jit_candidates.csv"
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow([
            "block", "sender", "pool_tag", "pool_address",
            "mint_tx", "swap_tx", "burn_tx",
            "swap_amount0", "swap_amount1",
            "tick_lower", "tick_upper", "range_width",
            "other_swaps_same_block",
        ])
        for c in candidates:
            writer.writerow([
                c.block, c.sender, c.pool_tag, c.pool_address,
                c.mint_tx, c.swap_tx, c.burn_tx,
                c.swap_amount0, c.swap_amount1,
                c.range_ticks[0], c.range_ticks[1], c.range_width,
                c.other_swaps_same_block,
            ])

    by_pool: dict[str, int] = defaultdict(int)
    widths: list[int] = []
    for c in candidates:
        by_pool[c.pool_tag] += 1
        widths.append(c.range_width)

    aggregate = {
        "window": {"from_block": from_block, "to_block": to_block, "blocks": to_block - from_block + 1},
        "total_jit_candidates": len(candidates),
        "by_pool": dict(by_pool),
        "range_width_stats": {
            "min": min(widths) if widths else None,
            "median": sorted(widths)[len(widths) // 2] if widths else None,
            "max": max(widths) if widths else None,
        },
    }

    json_path = OUT_DIR / "aggregate.json"
    json_path.write_text(json.dumps(aggregate, indent=2))

    print(f"\n[ok] wrote {len(candidates)} candidates to {csv_path}", file=sys.stderr)
    print(f"[ok] wrote summary to {json_path}", file=sys.stderr)
    print(json.dumps(aggregate, indent=2))


# ---------- entry ----------

def main() -> int:
    rpc = os.environ.get("MAINNET_RPC_URL", PUBLIC_RPC)
    print(f"[boot] RPC = {rpc}", file=sys.stderr)
    latest = get_latest_block(rpc)
    to_block = latest
    from_block = latest - BLOCK_WINDOW

    all_candidates: list[JITCandidate] = []
    for pool in TARGET_POOLS:
        try:
            events = gather_pool_events(rpc, pool, from_block, to_block)
            cands = find_jit_candidates(events)
            print(f"[{pool[2]}] found {len(cands)} JIT candidates in {len(events)} events", file=sys.stderr)
            all_candidates.extend(cands)
        except Exception as exc:
            print(f"[{pool[2]}] FAILED: {exc}", file=sys.stderr)

    write_outputs(all_candidates, from_block, to_block)
    return 0


if __name__ == "__main__":
    sys.exit(main())
