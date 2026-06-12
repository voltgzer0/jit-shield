"""
interface.py — the PUBLIC contract of the detection engine.

This file is open source on purpose. It defines:
  - the shape of a JIT-risk verdict (`ShieldSignal`),
  - the scorer interface every detector must satisfy (`Scorer`),
  - a fully open REFERENCE scorer (`ReferenceScorer`) that reproduces exactly what
    the on-chain hook can already prove by itself — the same-block sandwich-JIT
    heuristic. It is correct but deliberately limited: it cannot see add-first JIT
    (the documented GAP-1) because that needs signals the chain does not expose.

The precise detector that closes GAP-1 lives behind this interface, off-chain, and
is NOT published here. The engine loads it if present and falls back to the
reference scorer otherwise (see piranha.load_scorer). The public result is
verifiable; the method that produces the precise result is not.

Empty jug vs full jug: the reference scorer is the jug half-full — it holds water
but isn't the whole vessel. The private core is what fills it.
"""
from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Protocol


@dataclass
class Observation:
    """One window of pool activity, assembled by piranha from chain reads."""
    pool_id: str
    block: int
    # ordered events in the window: list of (kind, block, actor, detail)
    # kind in {"swap","add","remove"}
    events: list = field(default_factory=list)
    # current on-chain hook state for this pool
    last_swap_block: int = 0
    surge_pending: bool = False


@dataclass
class ShieldSignal:
    """A JIT-risk verdict for one pool/observation. This is the PUBLIC result shape."""
    pool_id: str
    block: int
    score: float            # 0.0 .. 1.0 risk
    verdict: str            # "clear" | "watch" | "jit"
    pattern: str            # which shape fired, e.g. "sandwich", "add-first", "none"
    detail: str = ""

    def to_dict(self):
        return asdict(self)


class Scorer(Protocol):
    """Every detector implements this. Input = Observation, output = ShieldSignal."""
    name: str

    def score(self, obs: Observation) -> ShieldSignal: ...


def _verdict_for(score: float) -> str:
    if score >= 0.66:
        return "jit"
    if score >= 0.33:
        return "watch"
    return "clear"


class ReferenceScorer:
    """
    Open, naive detector. Mirrors the on-chain hook's same-block heuristic:
    an ADD in the same block as a prior SWAP is sandwich-JIT-shaped.

    Catches GAP-2 shape (sandwich). Does NOT catch GAP-1 (classical add-first),
    by design — that is the part the private core supplies.
    """
    name = "reference"

    def score(self, obs: Observation) -> ShieldSignal:
        swap_seen = False
        for kind, _blk, _actor, _detail in obs.events:
            if kind == "swap":
                swap_seen = True
            elif kind == "add" and swap_seen:
                return ShieldSignal(
                    pool_id=obs.pool_id, block=obs.block, score=0.7,
                    verdict="jit", pattern="sandwich",
                    detail="add following a same-window swap (on-chain-provable)",
                )
        # On-chain state echo: if the hook itself flagged surge, surface it.
        if obs.surge_pending:
            return ShieldSignal(
                pool_id=obs.pool_id, block=obs.block, score=0.66,
                verdict="jit", pattern="sandwich",
                detail="hook surgePending=true",
            )
        return ShieldSignal(
            pool_id=obs.pool_id, block=obs.block, score=0.0,
            verdict="clear", pattern="none", detail="no same-block sandwich signal",
        )
