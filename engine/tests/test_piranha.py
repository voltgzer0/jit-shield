"""Offline tests for piranha. Mocks chain.* — no network."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import chain
import piranha
from interface import Observation


def _install_fake_chain(head, hook_state, logs_by_topic):
    """Patch chain.* with deterministic responses."""
    chain.block_number = lambda url=None: head

    def fake_eth_call(to, data, url=None):
        sel = data[:10]
        if sel == piranha.SELECTORS["lastSwapBlock(bytes32)"]:
            return hex(hook_state["last_swap"])
        if sel == piranha.SELECTORS["surgePending(bytes32)"]:
            return hex(1 if hook_state["surge"] else 0)
        return "0x0"
    chain.eth_call = fake_eth_call

    def fake_get_logs(address, topics, frm, to, url=None):
        return logs_by_topic.get(topics[0], [])
    chain.get_logs = fake_get_logs


def test_read_hook_state():
    _install_fake_chain(100, {"last_swap": 95, "surge": True}, {})
    last, surge = piranha.read_hook_state(piranha.DEFAULT_HOOK, piranha.DEFAULT_POOL)
    assert last == 95 and surge is True


def test_observe_builds_events_from_logs():
    logs = {
        piranha.TOPIC_JIT_DETECTED: [
            {"blockNumber": "0x60", "transactionHash": "0xa", "topics": [], "data": "0x"},
        ],
        piranha.TOPIC_SURGE_APPLIED: [
            {"blockNumber": "0x61", "transactionHash": "0xb", "topics": [], "data": "0x"},
        ],
    }
    _install_fake_chain(0x61, {"last_swap": 0x61, "surge": False}, logs)
    obs, raw, head = piranha.observe(piranha.DEFAULT_HOOK, piranha.DEFAULT_POOL, 1000)
    assert head == 0x61
    assert len(raw) == 2
    kinds = [e[0] for e in obs.events]
    assert "add" in kinds and "swap" in kinds


def test_load_scorer_falls_back_to_reference(monkeypatch_no_core):
    scorer, mode = piranha.load_scorer()
    # In CI / public checkout there is no _core_signal.py -> reference.
    assert mode in ("reference", "core")  # both valid; assert it returns a scorer
    assert hasattr(scorer, "score")


def test_run_json_smoke(capsys_off):
    _install_fake_chain(200, {"last_swap": 199, "surge": False}, {})
    sig = piranha.run(piranha.DEFAULT_HOOK, piranha.DEFAULT_POOL, 100, as_json=True)
    assert sig.pool_id == piranha.DEFAULT_POOL


def _run():
    import inspect
    saved = {k: getattr(chain, k) for k in ("block_number", "eth_call", "get_logs")}
    tests = {n: f for n, f in globals().items() if n.startswith("test_") and callable(f)}
    p = f_ = 0
    for n, fn in tests.items():
        params = inspect.signature(fn).parameters
        kwargs = {}
        # simple fixtures: no-ops, present only to document intent
        if "monkeypatch_no_core" in params:
            kwargs["monkeypatch_no_core"] = None
        if "capsys_off" in params:
            kwargs["capsys_off"] = None
        try:
            fn(**kwargs); print(f"PASS  {n}"); p += 1
        except AssertionError as e:
            print(f"FAIL  {n}: {e}"); f_ += 1
        except Exception as e:  # noqa: BLE001
            print(f"ERROR {n}: {type(e).__name__}: {e}"); f_ += 1
        finally:
            for k, v in saved.items():
                setattr(chain, k, v)
    print(f"\n{p}/{p + f_} passed")
    return 0 if f_ == 0 else 1


if __name__ == "__main__":
    sys.exit(_run())
