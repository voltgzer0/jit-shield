"""
chain.py — minimal read-only JSON-RPC client (stdlib only).

Reads public chain state: block number, contract calls, event logs. Never signs,
never sends a transaction. RPC endpoint comes from RPC_URL (defaults to a public
Sepolia node so the live readout works with no setup).

This is the eyes of the engine. It only observes.
"""
from __future__ import annotations

import json
import os
import urllib.request

DEFAULT_RPC = "https://ethereum-sepolia.publicnode.com"
TIMEOUT = 25


def rpc_url() -> str:
    return os.environ.get("RPC_URL", DEFAULT_RPC)


def _post(payload, url=None):
    url = url or rpc_url()
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=body,
        headers={"User-Agent": "jitshield-engine/1.0", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def call(method, params, url=None):
    """Single JSON-RPC call. Returns the `result` field or raises on RPC error."""
    resp = _post({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, url=url)
    if "error" in resp:
        raise RuntimeError(f"RPC error {method}: {resp['error']}")
    return resp.get("result")


def block_number(url=None) -> int:
    return int(call("eth_blockNumber", [], url=url), 16)


def eth_call(to, data, url=None) -> str:
    return call("eth_call", [{"to": to, "data": data}, "latest"], url=url)


def get_logs(address, topics, from_block, to_block, url=None):
    """eth_getLogs over [from_block, to_block] for one address + topic filter."""
    params = [{
        "address": address,
        "fromBlock": hex(from_block),
        "toBlock": hex(to_block) if isinstance(to_block, int) else to_block,
        "topics": topics,
    }]
    return call("eth_getLogs", params, url=url) or []


# --- ABI helpers (no external deps) ------------------------------------------
def selector(text_sig_keccak_hex: str) -> str:
    """First 4 bytes of a precomputed keccak hex (callers pass the known hash)."""
    h = text_sig_keccak_hex
    if h.startswith("0x"):
        h = h[2:]
    return "0x" + h[:8]


def encode_address(addr: str) -> str:
    a = addr.lower().replace("0x", "")
    return a.rjust(64, "0")


def encode_bytes32(b: str) -> str:
    return b.lower().replace("0x", "").rjust(64, "0")


def decode_uint(hexstr: str) -> int:
    if not hexstr or hexstr in ("0x", "0x0"):
        return 0
    return int(hexstr, 16)


def decode_address(word_hex: str) -> str:
    h = word_hex.lower().replace("0x", "").rjust(64, "0")
    return "0x" + h[-40:]
