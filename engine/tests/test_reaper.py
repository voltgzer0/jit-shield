"""Offline tests for reaper. Mocks chain.eth_call — no network."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import chain
import reaper
import piranha


def _install(accrued_by_cur, balance_by_cur):
    def fake_eth_call(to, data, url=None):
        sel = data[:10]
        arg = "0x" + data[10:]  # the address word
        addr = "0x" + data[-40:]
        if sel == piranha.SELECTORS["accruedFees(address)"]:
            return hex(accrued_by_cur.get(addr.lower(), 0))
        if sel == reaper.SEL_BALANCE_OF:
            return hex(balance_by_cur.get(to.lower(), 0))
        return "0x0"
    chain.eth_call = fake_eth_call


def test_reconcile_match():
    cur = "0x7ce8535d4fd28de2d929b03a7b6d9d6045f36872"
    _install({cur: 700000000000000}, {cur: 700000000000000})
    rows = reaper.reconcile(piranha.DEFAULT_HOOK, [cur])
    assert rows[0]["reconciled"] is True
    assert rows[0]["harvestable"] == 700000000000000


def test_reconcile_drift_detected():
    cur = "0x7ce8535d4fd28de2d929b03a7b6d9d6045f36872"
    _install({cur: 700000000000000}, {cur: 500000000000000})  # balance < book
    rows = reaper.reconcile(piranha.DEFAULT_HOOK, [cur])
    assert rows[0]["reconciled"] is False
    assert rows[0]["harvestable"] == 500000000000000  # min(book, balance)


def test_zero_position_is_reconciled():
    cur = "0x995b4cd6cc4bb7985b3869dc8edbd32fcd38a892"
    _install({}, {})
    rows = reaper.reconcile(piranha.DEFAULT_HOOK, [cur])
    assert rows[0]["reconciled"] is True
    assert rows[0]["harvestable"] == 0


def _run():
    saved = chain.eth_call
    tests = {n: f for n, f in globals().items() if n.startswith("test_") and callable(f)}
    p = f_ = 0
    for n, fn in tests.items():
        try:
            fn(); print(f"PASS  {n}"); p += 1
        except AssertionError as e:
            print(f"FAIL  {n}: {e}"); f_ += 1
        except Exception as e:  # noqa: BLE001
            print(f"ERROR {n}: {type(e).__name__}: {e}"); f_ += 1
        finally:
            chain.eth_call = saved
    print(f"\n{p}/{p + f_} passed")
    return 0 if f_ == 0 else 1


if __name__ == "__main__":
    sys.exit(_run())
