#!/usr/bin/env bash
# Plants the "Vectorize It" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="01-vectorize-it"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── solution.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — normalize-and-clip vectorization challenge
#
# Context: given a 1-D array of floats, normalize each value into [0, 1] via
#   normed = (x - lo) / (hi - lo)
# then clamp to [0.0, 1.0]:
#   out = max(0.0, min(1.0, normed))
#
# The slow reference implementation below uses a Python loop. Your job is to
# implement fast_normalize_and_clip() using NumPy so it:
#   1. Returns the same values (within floating-point tolerance).
#   2. Runs within 1 second on a 2 000 000-element array.
#
# Do NOT modify _slow_normalize_and_clip.

import numpy as np
from typing import Union


def _slow_normalize_and_clip(arr, lo: float, hi: float):
    """Reference implementation — correct but O(n) Python iterations."""
    out = []
    for x in arr:
        normed = (x - lo) / (hi - lo)
        out.append(max(0.0, min(1.0, normed)))
    return out


def fast_normalize_and_clip(arr: Union[list, np.ndarray], lo: float, hi: float) -> np.ndarray:
    """Vectorized implementation — must produce the same result as the slow version.

    Args:
        arr: 1-D sequence of floats (list or numpy array).
        lo:  lower bound for normalization (maps to 0.0).
        hi:  upper bound for normalization (maps to 1.0).

    Returns:
        numpy.ndarray of float64 values clamped to [0.0, 1.0].
    """
    # TODO: replace this stub with a vectorized NumPy implementation.
    raise NotImplementedError("implement fast_normalize_and_clip with NumPy")
PYEOF

# ── visible sample tests ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import sys, os, time
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np
from solution import _slow_normalize_and_clip, fast_normalize_and_clip


def test_correctness_small():
    """Fast version must match slow version on a small known array."""
    arr = [-1.0, 0.0, 0.5, 1.0, 1.5, 2.0, 3.0]
    lo, hi = 0.0, 2.0
    expected = _slow_normalize_and_clip(arr, lo, hi)
    result = fast_normalize_and_clip(arr, lo, hi)
    assert np.allclose(result, expected, atol=1e-9), \
        f"mismatch:\n  expected {expected}\n  got      {list(result)}"


def test_speed_smoke():
    """Quick smoke check: 100k elements should finish in under 0.5s."""
    rng = np.random.default_rng(42)
    arr = rng.uniform(-5, 10, size=100_000)
    start = time.perf_counter()
    fast_normalize_and_clip(arr, 0.0, 5.0)
    elapsed = time.perf_counter() - start
    assert elapsed < 0.5, f"100k elements took {elapsed:.3f}s — way too slow"
PYEOF

echo
echo "Work directory   : $WORK"
echo
echo "Task             : implement fast_normalize_and_clip() in solution.py"
echo "                   using NumPy so all tests pass."
echo
echo "Prerequisites    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate && pip install pytest numpy"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag    : bash courses/course-21-data-science-python/challenges/$SLUG/verify.sh"
