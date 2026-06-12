"""Offline tests for the public scorer interface. No network."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from interface import Observation, ReferenceScorer, ShieldSignal, _verdict_for


def test_verdict_bands():
    assert _verdict_for(0.0) == "clear"
    assert _verdict_for(0.4) == "watch"
    assert _verdict_for(0.9) == "jit"


def test_reference_flags_sandwich():
    obs = Observation(pool_id="0xpool", block=10,
                      events=[("swap", 9, "u", "tx1"), ("add", 9, "bot", "tx2")])
    sig = ReferenceScorer().score(obs)
    assert isinstance(sig, ShieldSignal)
    assert sig.verdict == "jit"
    assert sig.pattern == "sandwich"


def test_reference_clear_on_plain_activity():
    obs = Observation(pool_id="0xpool", block=10,
                      events=[("add", 9, "lp", "tx1")])  # add with no prior swap
    sig = ReferenceScorer().score(obs)
    assert sig.verdict == "clear"
    assert sig.pattern == "none"


def test_reference_echoes_surge_pending_state():
    obs = Observation(pool_id="0xpool", block=10, events=[], surge_pending=True)
    sig = ReferenceScorer().score(obs)
    assert sig.verdict == "jit"


def test_reference_does_not_catch_add_first_gap1():
    # ADD first, then SWAP, then REMOVE — classical add-first JIT.
    obs = Observation(pool_id="0xpool", block=10, events=[
        ("add", 9, "bot", "tx1"), ("swap", 9, "victim", "tx2"), ("remove", 9, "bot", "tx3"),
    ])
    sig = ReferenceScorer().score(obs)
    # Reference cannot see add-first JIT — this is the gap the private core fills.
    assert sig.verdict == "clear"


def _run():
    tests = {n: f for n, f in globals().items() if n.startswith("test_") and callable(f)}
    p = f_ = 0
    for n, fn in tests.items():
        try:
            fn(); print(f"PASS  {n}"); p += 1
        except AssertionError as e:
            print(f"FAIL  {n}: {e}"); f_ += 1
        except Exception as e:  # noqa: BLE001
            print(f"ERROR {n}: {type(e).__name__}: {e}"); f_ += 1
    print(f"\n{p}/{p + f_} passed")
    return 0 if f_ == 0 else 1


if __name__ == "__main__":
    sys.exit(_run())
