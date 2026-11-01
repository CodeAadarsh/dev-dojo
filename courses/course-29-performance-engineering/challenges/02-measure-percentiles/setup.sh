#!/usr/bin/env bash
# Plants the "Measure Percentiles" starter project into the work directory.
# Idempotent — re-running overwrites source files but not .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/02-measure-percentiles"
mkdir -p "$WORK/tests"

# ── latency_analysis.py skeleton ─────────────────────────────────────────────
cat > "$WORK/latency_analysis.py" << 'PYEOF'
"""
SLO reporting library: compute percentile latencies and detect SLO breaches.

Two functions to implement:

  compute_percentile(data, p)   -- p-th percentile via linear interpolation
  check_slo(latencies, p99_ms)  -- True if p99 exceeds the threshold (breach)

The interpolation formula:
  rank   = p / 100 * (n - 1)          # floating-point index into sorted data
  lower  = int(rank)
  upper  = min(lower + 1, n - 1)
  result = data[lower] + (rank - lower) * (data[upper] - data[lower])

Edge cases you must handle:
  - Empty list                     -> raise ValueError
  - Single-element list            -> return that element for any p
  - p == 0                         -> sorted_data[0]
  - p == 100                       -> sorted_data[-1]
  - Unsorted input                 -> sort internally before computing
"""
from typing import List


def compute_percentile(data: List[float], p: float) -> float:
    """
    Return the p-th percentile of data using linear interpolation.

    Args:
        data: list of numeric latency values (may be unsorted)
        p:    percentile in [0, 100]

    Raises:
        ValueError: if data is empty or p is outside [0, 100]
    """
    raise NotImplementedError("implement compute_percentile")


def check_slo(latencies: List[float], p99_threshold_ms: float) -> bool:
    """
    Return True if the p99 latency exceeds p99_threshold_ms (SLO breach).
    Return False if p99 is at or below the threshold.
    """
    raise NotImplementedError("implement check_slo")
PYEOF

# ── tests/test_latency_visible.py ────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_latency_visible.py" << 'PYEOF'
import sys
import os
import pytest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from latency_analysis import compute_percentile, check_slo

# Dataset: [100, 200, ..., 1000] — 10 evenly spaced samples
DATA = [float(i * 100) for i in range(1, 11)]  # [100.0, 200.0, ..., 1000.0]


def test_p50():
    # rank = 0.5 * 9 = 4.5 -> data[4] + 0.5*(data[5]-data[4]) = 500+50 = 550
    assert abs(compute_percentile(DATA, 50) - 550.0) < 0.01


def test_p0_is_minimum():
    assert abs(compute_percentile(DATA, 0) - 100.0) < 0.01


def test_p100_is_maximum():
    assert abs(compute_percentile(DATA, 100) - 1000.0) < 0.01


def test_unsorted_input():
    shuffled = [500.0, 100.0, 300.0, 200.0, 400.0]
    # sorted: [100, 200, 300, 400, 500], p50 rank = 0.5*4 = 2.0 -> data[2] = 300
    assert abs(compute_percentile(shuffled, 50) - 300.0) < 0.01


def test_empty_raises():
    with pytest.raises(ValueError):
        compute_percentile([], 50)


def test_slo_breach():
    # p99 of DATA = 991.0; threshold 900 -> breach
    assert check_slo(DATA, 900.0) is True


def test_slo_met():
    # p99 of DATA = 991.0; threshold 1000 -> met
    assert check_slo(DATA, 1000.0) is False
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement compute_percentile and check_slo in latency_analysis.py."
echo "                 Use the linear interpolation formula in the module docstring."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run smoke tests: cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-29-performance-engineering/challenges/02-measure-percentiles/verify.sh"
