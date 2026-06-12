"""
reaper.py — the settlement module.

Where piranha senses, the reaper accounts. It grinds the protocol-fee position to
the bone: for each currency the hook has touched, it reconciles the hook's internal
bookkeeping (`accruedFees`) against the real ERC20 balance the hook holds, and
reports exactly what is harvestable.

This is the honest end-to-end proof surface: bookkeeping == balance means the
mechanism accrued a real, tradeable position, not just events. Read-only — the
actual withdrawal is an owner on-chain action, not performed here.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import chain  # noqa: E402
from piranha import DEFAULT_HOOK, SELECTORS  # noqa: E402

# ERC20 balanceOf(address) selector.
SEL_BALANCE_OF = "0x70a08231"

# Sepolia test currencies from DEPLOYMENTS.md.
DEFAULT_CURRENCIES = [
    "0x7CE8535D4fD28DE2d929B03A7B6d9d6045F36872",  # JTA
    "0x995b4cD6Cc4Bb7985b3869DC8eDBd32FCd38a892",  # JTB
]


def accrued(hook, currency, url=None) -> int:
    data = SELECTORS["accruedFees(address)"] + chain.encode_address(currency)
    return chain.decode_uint(chain.eth_call(hook, data, url=url))


def erc20_balance(token, holder, url=None) -> int:
    data = SEL_BALANCE_OF + chain.encode_address(holder)
    return chain.decode_uint(chain.eth_call(token, data, url=url))


def reconcile(hook, currencies, url=None):
    """Return per-currency {accrued, balance, reconciled, harvestable}."""
    rows = []
    for cur in currencies:
        book = accrued(hook, cur, url=url)
        bal = erc20_balance(cur, hook, url=url)
        rows.append({
            "currency": cur,
            "accrued": book,
            "balance": bal,
            "reconciled": book == bal,
            "harvestable": min(book, bal),
        })
    return rows


def run(hook, currencies, url=None, as_json=False):
    rows = reconcile(hook, currencies, url=url)
    total = sum(r["harvestable"] for r in rows)
    all_ok = all(r["reconciled"] for r in rows)

    if as_json:
        print(json.dumps({"hook": hook, "rows": rows,
                          "total_harvestable": total, "all_reconciled": all_ok}, indent=2))
        return rows

    print("=== REAPER | fee reconciliation | live ===")
    print(f"  hook : {hook}")
    for r in rows:
        mark = "OK " if r["reconciled"] else "DRIFT"
        print(f"  [{mark}] {r['currency']}")
        print(f"         accrued(book) = {r['accrued']}")
        print(f"         balance(real) = {r['balance']}")
        print(f"         harvestable   = {r['harvestable']}")
    print(f"  total harvestable : {total}")
    print(f"  all reconciled    : {all_ok}")
    return rows


def main(argv=None):
    ap = argparse.ArgumentParser(description="JITShield Reaper — fee reconciliation (read-only)")
    ap.add_argument("--hook", default=DEFAULT_HOOK)
    ap.add_argument("--currencies", default=",".join(DEFAULT_CURRENCIES))
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    curs = [c.strip() for c in args.currencies.split(",") if c.strip()]
    run(args.hook, curs, as_json=args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
