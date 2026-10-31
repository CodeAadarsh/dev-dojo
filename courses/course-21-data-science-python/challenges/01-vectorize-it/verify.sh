#!/usr/bin/env bash
# Verifier for "Vectorize It".
# Writes a hidden pytest suite into a temp dir, runs it against solution.py,
# and prints the flag only when every test passes.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="01-vectorize-it"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{numpy_vectorize_or_die}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]           || fail "work directory missing — run setup.sh first"
[ -f "$WORK/solution.py" ] || fail "solution.py not found — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest numpy"
fi

mkdir -p _verify

cat > "_verify/test_hidden.py" << 'PYEOF'
import sys, os, time
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np
from solution import _slow_normalize_and_clip, fast_normalize_and_clip


# ── helpers ──────────────────────────────────────────────────────────────────

def _check(arr, lo, hi, label=""):
    expected = np.array(_slow_normalize_and_clip(arr, lo, hi), dtype=float)
    result = fast_normalize_and_clip(arr, lo, hi)
    assert isinstance(result, np.ndarray), \
        f"{label}: must return numpy.ndarray, got {type(result)}"
    assert result.shape == expected.shape, \
        f"{label}: shape mismatch: expected {expected.shape}, got {result.shape}"
    assert np.allclose(result, expected, atol=1e-9), \
        f"{label}: value mismatch (first diff at index {(~np.isclose(result, expected, atol=1e-9)).argmax()})"


# ── correctness ───────────────────────────────────────────────────────────────

def test_basic_range():
    _check([-1.0, 0.0, 0.5, 1.0, 1.5, 2.0, 3.0], 0.0, 2.0, "basic_range")


def test_already_in_range():
    arr = [0.1, 0.3, 0.7, 0.9]
    _check(arr, 0.0, 1.0, "already_in_range")


def test_all_below_lo():
    arr = [-5.0, -4.0, -3.0, -2.0, -1.0]
    _check(arr, 0.0, 10.0, "all_below_lo")


def test_all_above_hi():
    arr = [15.0, 20.0, 100.0]
    _check(arr, 0.0, 10.0, "all_above_hi")


def test_negative_lo_hi():
    arr = [-3.0, -1.0, 0.0, 1.0, 3.0]
    _check(arr, -2.0, 2.0, "negative_lo_hi")


def test_seeded_medium():
    rng = np.random.default_rng(2024)
    arr = rng.uniform(-100, 100, size=10_000)
    _check(arr, -50.0, 50.0, "seeded_medium")


def test_seeded_large_correctness():
    rng = np.random.default_rng(1337)
    arr = rng.uniform(0, 200, size=200_000)
    _check(arr, 20.0, 180.0, "seeded_large_correctness")


def test_returns_ndarray():
    result = fast_normalize_and_clip([1.0, 2.0, 3.0], 0.0, 4.0)
    assert isinstance(result, np.ndarray), \
        f"return type must be numpy.ndarray, got {type(result)}"


def test_accepts_list_input():
    plain_list = [0.0, 1.0, 2.0, 3.0, 4.0]
    _check(plain_list, 1.0, 3.0, "accepts_list_input")


def test_accepts_ndarray_input():
    arr = np.linspace(-1, 2, 50)
    _check(arr, 0.0, 1.0, "accepts_ndarray_input")


def test_single_element_in_range():
    _check([0.5], 0.0, 1.0, "single_element_in_range")


def test_single_element_below():
    _check([-10.0], 0.0, 1.0, "single_element_below")


def test_single_element_above():
    _check([10.0], 0.0, 1.0, "single_element_above")


# ── performance ───────────────────────────────────────────────────────────────

def test_speed_two_million():
    """Must complete 2M elements in under 1 second."""
    rng = np.random.default_rng(9999)
    arr = rng.uniform(-1000, 1000, size=2_000_000)
    start = time.perf_counter()
    result = fast_normalize_and_clip(arr, -500.0, 500.0)
    elapsed = time.perf_counter() - start
    assert elapsed < 1.0, \
        f"2M elements took {elapsed:.3f}s (budget: 1.0s) — use NumPy vectorization, not a Python loop"
    # also spot-check correctness on a small slice
    expected_slice = np.array(_slow_normalize_and_clip(arr[:20], -500.0, 500.0))
    assert np.allclose(result[:20], expected_slice, atol=1e-9), \
        "performance test passed but first-20 values are wrong — check your formula"
PYEOF

if $PYTEST "_verify/test_hidden.py" -q 2>&1; then
    rm -rf "_verify"
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    rm -rf "_verify"
    fail "test suite has failures — fix your implementation and retry"
fi
