#!/usr/bin/env bash
# Plants the "LLM Gateway with Cache" starter into the work directory.
# Idempotent — re-running overwrites stub and tests but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/06-llm-gateway-with-cache"
mkdir -p "$WORK/tests"

# ── gateway.py skeleton ───────────────────────────────────────────────────────
cat > "$WORK/gateway.py" << 'PYEOF'
# gateway.py — LLM gateway with exact + semantic cache skeleton
#
# MockLLM, embed(), cosine_similarity(), and SIMILARITY_THRESHOLD are
# provided and deterministic.  Implement LLMGateway.complete() only.
#
# Three-stage completion strategy (in order):
#   1. Exact cache: self._exact[prompt] — return if present
#   2. Semantic cache: iterate self._semantic; for each (cached_emb, cached_response),
#      return cached_response if cosine_similarity(embed(prompt), cached_emb) >= threshold
#   3. Model call: try self.primary.complete(prompt); on ANY exception call
#      self.fallback.complete(prompt).  Store result in BOTH caches before returning.
#
# self._exact    : dict[str, str]              — prompt -> response
# self._semantic : list[tuple[list, str]]      — (embedding_vector, response)

import math
from typing import List, Tuple

# ── provided utilities (do not modify) ───────────────────────────────────────

VOCAB: List[str] = [
    "what", "is", "the", "capital", "of", "france", "germany",
    "paris", "berlin", "calculate", "sum", "add", "multiply",
]


def embed(text: str) -> List[float]:
    """
    Bag-of-words embedding over VOCAB.
    Each word present in text (lowercased, whitespace-split) → 1.0, else 0.0.
    Deterministic and offline.
    """
    words = set(text.lower().split())
    return [1.0 if w in words else 0.0 for w in VOCAB]


def cosine_similarity(a: List[float], b: List[float]) -> float:
    """Standard cosine similarity; returns 0.0 if either vector is all-zeros."""
    dot = sum(x * y for x, y in zip(a, b))
    mag_a = math.sqrt(sum(x * x for x in a))
    mag_b = math.sqrt(sum(x * x for x in b))
    if mag_a == 0.0 or mag_b == 0.0:
        return 0.0
    return dot / (mag_a * mag_b)


class MockLLM:
    """
    Deterministic mock model.
    call_count increments on every call, including calls that raise.
    Set should_fail = True to simulate an unavailable model.
    """
    def __init__(self, name: str = "primary"):
        self.name = name
        self.call_count = 0
        self.should_fail = False

    def complete(self, prompt: str) -> str:
        self.call_count += 1
        if self.should_fail:
            raise RuntimeError(f"{self.name} model unavailable")
        return f"{self.name}:r{abs(hash(prompt)) % 10000}"


SIMILARITY_THRESHOLD: float = 0.75


# ── gateway (implement this) ──────────────────────────────────────────────────

class LLMGateway:
    """
    Cache-then-model LLM gateway.

    Check order: exact cache → semantic cache → model call (with fallback).
    Store every new model response in both caches before returning.
    """

    def __init__(
        self,
        primary: MockLLM,
        fallback: MockLLM,
        threshold: float = SIMILARITY_THRESHOLD,
    ):
        self.primary = primary
        self.fallback = fallback
        self.threshold = threshold
        self._exact: dict = {}           # prompt -> response
        self._semantic: List[Tuple[List[float], str]] = []  # (embedding, response)

    def complete(self, prompt: str) -> str:
        """
        Return a response for prompt, using caches before calling any model.
        Store new responses in both caches.
        """
        raise NotImplementedError("Implement LLMGateway.complete()")
PYEOF

# ── tests/__init__.py ─────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

# ── tests/test_gateway.py ─────────────────────────────────────────────────────
cat > "$WORK/tests/test_gateway.py" << 'PYEOF'
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from gateway import LLMGateway, MockLLM, cosine_similarity, embed, SIMILARITY_THRESHOLD


def _fresh() -> tuple:
    """Return a new (primary, fallback, gateway) triple."""
    p = MockLLM("primary")
    f = MockLLM("fallback")
    return p, f, LLMGateway(p, f)


# ── exact cache ────────────────────────────────────────────────────────────────

def test_exact_cache_on_repeated_prompt():
    p, f, gw = _fresh()
    r1 = gw.complete("capital of france")
    r2 = gw.complete("capital of france")
    assert r1 == r2, "Exact cache must return the same response for identical prompts"
    assert p.call_count == 1, (
        f"Second identical prompt must hit the exact cache; "
        f"got {p.call_count} model calls (expected 1)"
    )


def test_exact_cache_three_repetitions():
    p, f, gw = _fresh()
    for _ in range(4):
        gw.complete("what is the capital of germany")
    assert p.call_count == 1, (
        f"4 identical prompts must produce exactly 1 model call; got {p.call_count}"
    )


# ── semantic cache ─────────────────────────────────────────────────────────────

def test_semantic_cache_hits_on_similar_prompt():
    # Sanity-check that the test vectors are actually similar enough
    sim = cosine_similarity(embed("capital of france"), embed("france capital"))
    assert sim >= SIMILARITY_THRESHOLD, (
        f"Test assumption violated: similarity={sim:.4f} < threshold={SIMILARITY_THRESHOLD}. "
        "embed() or SIMILARITY_THRESHOLD was modified."
    )
    p, f, gw = _fresh()
    gw.complete("capital of france")
    gw.complete("france capital")       # similar prompt — must hit semantic cache
    assert p.call_count == 1, (
        f"Similar prompts must share a semantic cache entry; "
        f"got {p.call_count} model calls (expected 1)"
    )


def test_semantic_cache_misses_on_dissimilar_prompt():
    # Sanity-check that dissimilar vectors are below threshold
    sim = cosine_similarity(embed("capital of france"), embed("what is 2+2"))
    assert sim < SIMILARITY_THRESHOLD, (
        f"Test assumption violated: similarity={sim:.4f} >= threshold={SIMILARITY_THRESHOLD}. "
        "embed() or SIMILARITY_THRESHOLD was modified."
    )
    p, f, gw = _fresh()
    gw.complete("capital of france")
    gw.complete("what is 2+2")          # dissimilar — must NOT hit semantic cache
    assert p.call_count == 2, (
        f"Dissimilar prompts must each call the primary model; got {p.call_count}"
    )


# ── fallback ───────────────────────────────────────────────────────────────────

def test_fallback_on_primary_failure():
    p, f, gw = _fresh()
    p.should_fail = True
    result = gw.complete("any prompt at all")
    assert result is not None and result != "", \
        "Gateway must return a non-empty response even when primary fails"
    assert p.call_count == 1, \
        "Primary must be attempted before falling back"
    assert f.call_count == 1, \
        "Fallback must be called exactly once when primary raises"


def test_fallback_response_cached():
    p, f, gw = _fresh()
    p.should_fail = True
    gw.complete("cached fallback prompt")
    gw.complete("cached fallback prompt")  # second call — must hit exact cache
    assert f.call_count == 1, (
        "Fallback response must be stored in cache; "
        "second identical prompt should not call fallback again"
    )


def test_primary_used_when_healthy():
    p, f, gw = _fresh()
    gw.complete("hello world")
    assert p.call_count == 1
    assert f.call_count == 0, \
        "Fallback must not be called when primary succeeds"
PYEOF

echo
echo "Work directory  : $WORK"
echo
echo "Task            : implement LLMGateway.complete() in $WORK/gateway.py"
echo "                  so all 7 tests pass."
echo
echo "Prerequisites   :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run tests       : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag   : bash courses/course-27-llmops/challenges/06-llm-gateway-with-cache/verify.sh"
