#!/usr/bin/env bash
# Verifier for "Cache to Hit SLO".
# Runs a hidden pytest suite that checks correctness AND call count:
#   - unbounded cache: total calls <= 50 (one per unique key)
#   - bounded LRU(20): total calls <= 200 (Zipf trace, 50 unique keys)
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/03-cache-to-hit-slo"
FLAG='KUBE{cache_your_way_to_slo}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/cache_optimizer.py" ] || fail "cache_optimizer.py not found — run setup.sh first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

TMPTEST="$(mktemp /tmp/test_cache_hidden_XXXXXX.py)"
trap 'rm -f "$TMPTEST"' EXIT

cat > "$TMPTEST" << 'PYEOF'
import sys
import os
import random

_work = os.path.expanduser("~/.kube-dojo-work/03-cache-to-hit-slo")
sys.path.insert(0, _work)
from cache_optimizer import process_requests


# ── shared deterministic 'expensive' function ─────────────────────────────────

def _make_expensive():
    """Returns a deterministic hash function + its call counter."""
    counts = [0]

    def fn(key: str) -> str:
        counts[0] += 1
        h = 0
        for c in key:
            h = (h * 31 + ord(c)) & 0xFFFFFFFF
        return f"result_{h:08x}"

    return fn, counts


def _expected_result(key: str) -> str:
    h = 0
    for c in key:
        h = (h * 31 + ord(c)) & 0xFFFFFFFF
    return f"result_{h:08x}"


# ── unbounded cache ────────────────────────────────────────────────────────────

def test_unbounded_correctness():
    fn, _ = _make_expensive()
    trace = ["svc_alpha", "svc_beta", "svc_alpha", "svc_gamma", "svc_beta", "svc_alpha"]
    result = process_requests(trace, fn, max_cache_size=None)
    for key in ["svc_alpha", "svc_beta", "svc_gamma"]:
        assert key in result, f"Key '{key}' missing from result"
        assert result[key] == _expected_result(key), f"Wrong result for '{key}'"


def test_unbounded_all_unique_keys_present():
    fn, _ = _make_expensive()
    random.seed(42)
    unique_keys = [f"req_{i:03d}" for i in range(50)]
    trace = random.choices(unique_keys, k=1000)
    result = process_requests(trace, fn, max_cache_size=None)
    for key in set(trace):
        assert key in result, f"Key '{key}' missing"
        assert result[key] == _expected_result(key), f"Wrong value for '{key}'"


def test_unbounded_call_count():
    """50 unique keys, 1000 requests. Unbounded cache: exactly one call per unique key."""
    fn, counts = _make_expensive()
    random.seed(42)
    unique_keys = [f"req_{i:03d}" for i in range(50)]
    trace = random.choices(unique_keys, k=1000)
    process_requests(trace, fn, max_cache_size=None)
    n_unique = len(set(trace))
    assert counts[0] <= n_unique, (
        f"expensive_fn called {counts[0]} times; "
        f"unbounded cache must call each of the {n_unique} unique keys at most once"
    )


def test_unbounded_empty_trace():
    fn, counts = _make_expensive()
    result = process_requests([], fn, max_cache_size=None)
    assert result == {}, "Empty trace should return empty dict"
    assert counts[0] == 0, "No calls for empty trace"


# ── bounded LRU cache ─────────────────────────────────────────────────────────

def test_bounded_correctness_small():
    """3 unique keys, cache size 2 — eviction happens but results must be correct."""
    fn, _ = _make_expensive()
    trace = ["a", "b", "c", "a", "b", "c", "a"]
    result = process_requests(trace, fn, max_cache_size=2)
    for key in ["a", "b", "c"]:
        assert result[key] == _expected_result(key), f"Wrong result for '{key}'"


def test_bounded_all_keys_in_result():
    """All unique keys from trace must appear in the result dict."""
    fn, _ = _make_expensive()
    random.seed(99)
    unique_keys = [f"req_{i:03d}" for i in range(50)]
    weights = [1.0 / (i + 1) for i in range(50)]   # Zipf
    trace = random.choices(unique_keys, k=1000, weights=weights)
    result = process_requests(trace, fn, max_cache_size=20)
    for key in set(trace):
        assert key in result, f"Key '{key}' missing from result"
        assert result[key] == _expected_result(key)


def test_bounded_lru_call_count():
    """
    Zipf-distributed trace: 50 unique keys, 1000 requests, cache_size=20.
    Hot top-20 keys dominate (Zipf). A correct LRU significantly reduces calls.
    No-cache baseline: 1000 calls. Target: ≤400 (a correct LRU makes ~200-350).
    Any implementation that never caches would hit ~1000 and fail.
    """
    fn, counts = _make_expensive()
    random.seed(99)
    unique_keys = [f"req_{i:03d}" for i in range(50)]
    weights = [1.0 / (i + 1) for i in range(50)]   # key_0 is 50x hotter than key_49
    trace = random.choices(unique_keys, k=1000, weights=weights)
    process_requests(trace, fn, max_cache_size=20)
    assert counts[0] <= 400, (
        f"expensive_fn called {counts[0]} times with cache_size=20 and "
        f"{len(set(trace))} unique keys over 1000 requests; "
        f"a no-cache baseline makes 1000 calls; a correct LRU(20) makes ≤400 — "
        f"ensure your cache is actually caching and evicting LRU entries"
    )


def test_lru_evicts_least_recently_used():
    """
    Verify LRU eviction order: fill cache with a,b,c (size=2 → c evicts a),
    then access a again — must call expensive_fn for a (was evicted).
    An unlimited cache would only make 3 calls; correct LRU(2) makes exactly 4.
    """
    fn, counts = _make_expensive()
    # cache_size=2; insert a (1 call), insert b (2 calls, cache full)
    # insert c: miss (3 calls), evicts a (LRU) -> cache={b,c}
    # access a: miss because it was evicted (4 calls) -> cache={c,a}
    trace = ["a", "b", "c", "a"]
    process_requests(trace, fn, max_cache_size=2)
    assert counts[0] >= 4, (
        f"With cache_size=2 and trace [a,b,c,a], inserting 'c' must evict 'a' (the LRU entry); "
        f"'a' on the 4th request is a cache miss and requires a recompute — "
        f"expected exactly 4 calls, got {counts[0]}. "
        f"An unlimited cache (ignoring max_cache_size) would make only 3."
    )
PYEOF

if "$PYTEST" "$TMPTEST" -v 2>&1; then
    echo
    echo "All checks passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "checks failed — fix your implementation and retry"
fi
