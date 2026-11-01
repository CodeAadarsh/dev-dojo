#!/usr/bin/env bash
# Plants the "Cache to Hit SLO" starter project into the work directory.
# Idempotent — re-running overwrites source files but not .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/03-cache-to-hit-slo"
mkdir -p "$WORK/tests"

# ── cache_optimizer.py skeleton ──────────────────────────────────────────────
cat > "$WORK/cache_optimizer.py" << 'PYEOF'
"""
Service mesh request handler with a missing cache layer.

expensive_compute simulates a slow downstream call (DB query, API, etc.).
It is deterministic: the same key always returns the same value.

The call counter (_call_count) is incremented each time expensive_compute
is invoked — use reset_call_count() before a test run and get_call_count()
after to see how many calls your implementation made.

Your task: implement process_requests so that repeated keys in the trace
skip the expensive call by returning the cached result.
"""
from typing import Callable, Dict, Any, Optional

# ── expensive_compute (DO NOT MODIFY) ────────────────────────────────────────
_call_count: int = 0


def expensive_compute(key: str) -> str:
    """
    Simulates an expensive downstream call.
    Deterministic: same key always returns same result.
    Increments the global call counter each time it is invoked.
    """
    global _call_count
    _call_count += 1
    h = 0
    for c in key:
        h = (h * 31 + ord(c)) & 0xFFFFFFFF
    return f"result_{h:08x}"


def get_call_count() -> int:
    """Return the number of times expensive_compute has been called."""
    return _call_count


def reset_call_count() -> None:
    """Reset the call counter to 0 before a test run."""
    global _call_count
    _call_count = 0


# ── process_requests (implement this) ────────────────────────────────────────
def process_requests(
    trace: list,
    expensive_fn: Callable[[str], Any] = expensive_compute,
    max_cache_size: Optional[int] = None,
) -> Dict[str, Any]:
    """
    Process each request key in trace using expensive_fn.

    Cache results so repeated keys avoid redundant computation:
      - max_cache_size is None  -> unbounded cache (plain dict).
      - max_cache_size > 0      -> LRU eviction when cache is full.
                                   Evict the least-recently-used entry.

    Returns a dict {unique_key: result} for every unique key in trace.

    Hint for LRU:
        from collections import OrderedDict
        cache = OrderedDict()
        cache.move_to_end(key)          # promote to MRU
        cache.popitem(last=False)       # evict LRU (the head)
    """
    raise NotImplementedError("implement process_requests")
PYEOF

# ── tests/test_cache_visible.py ──────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_cache_visible.py" << 'PYEOF'
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from cache_optimizer import process_requests, expensive_compute, reset_call_count, get_call_count


def test_correctness_all_unique_keys_present():
    trace = ["alpha", "beta", "gamma", "alpha", "beta"]
    result = process_requests(trace, expensive_compute)
    for key in ["alpha", "beta", "gamma"]:
        assert key in result, f"Key '{key}' missing from result"
        assert result[key] == expensive_compute(key), f"Wrong result for '{key}'"


def test_unbounded_cache_calls_each_key_once():
    reset_call_count()
    trace = ["x", "y", "z", "x", "y", "x"]    # 3 unique keys, 6 requests
    process_requests(trace, expensive_compute, max_cache_size=None)
    assert get_call_count() <= 3, (
        f"expensive_compute was called {get_call_count()} times; "
        f"with a cache it should be called at most once per unique key (≤3)"
    )


def test_bounded_cache_gives_correct_results():
    # cache smaller than unique keys — LRU evicts, but results must be correct
    trace = ["a", "b", "c", "d", "e", "a", "b", "c", "d", "e"]
    result = process_requests(trace, expensive_compute, max_cache_size=3)
    for key in ["a", "b", "c", "d", "e"]:
        assert result[key] == expensive_compute(key), f"Wrong result for '{key}'"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement process_requests in cache_optimizer.py."
echo "                 Part 1: unbounded dict cache (max_cache_size=None)."
echo "                 Part 2: LRU eviction cache  (max_cache_size=N)."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run smoke tests: cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-29-performance-engineering/challenges/03-cache-to-hit-slo/verify.sh"
