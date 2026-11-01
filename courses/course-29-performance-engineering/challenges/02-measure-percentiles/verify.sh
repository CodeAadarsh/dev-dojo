#!/usr/bin/env bash
# Verifier for "Measure Percentiles".
# Runs a hidden pytest suite asserting exact interpolated values (±0.01)
# on multiple datasets including edge cases, plus SLO breach detection.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/02-measure-percentiles"
FLAG='KUBE{percentile_math_never_lies}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/latency_analysis.py" ] || fail "latency_analysis.py not found — run setup.sh first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

TMPTEST="$(mktemp /tmp/test_percentile_hidden_XXXXXX.py)"
trap 'rm -f "$TMPTEST"' EXIT

cat > "$TMPTEST" << 'PYEOF'
import sys
import os
import math
import pytest

_work = os.path.expanduser("~/.kube-dojo-work/02-measure-percentiles")
sys.path.insert(0, _work)
from latency_analysis import compute_percentile, check_slo

TOL = 0.01   # tolerance: within 0.01 ms of the expected value

# Reference dataset 1: 10 evenly spaced samples
D10 = [float(i * 100) for i in range(1, 11)]   # [100.0, 200.0, ..., 1000.0]

# Reference dataset 2: 5 samples (clean whole-index hits at p50, p25, p75)
D5 = [5.0, 1.0, 3.0, 7.0, 9.0]   # sorted: [1, 3, 5, 7, 9]

# Reference dataset 3: single element
D1 = [42.0]

# Reference dataset 4: two elements
D2 = [10.0, 90.0]

# Reference dataset 5: larger real-world-shaped sample
import random
random.seed(7)
D100 = sorted([random.gauss(200, 50) for _ in range(100)])  # normal(mu=200, sigma=50)


def _interp(sorted_data, p):
    """Reference implementation for comparison."""
    n = len(sorted_data)
    if n == 0:
        raise ValueError("empty")
    if n == 1:
        return float(sorted_data[0])
    rank = p / 100.0 * (n - 1)
    lower = int(rank)
    upper = min(lower + 1, n - 1)
    frac = rank - lower
    return sorted_data[lower] + frac * (sorted_data[upper] - sorted_data[lower])


# ── D10 exact values ──────────────────────────────────────────────────────────

def test_d10_p0():
    assert abs(compute_percentile(D10, 0) - 100.0) < TOL

def test_d10_p50():
    # rank = 0.5*9 = 4.5 -> 500 + 0.5*100 = 550.0
    assert abs(compute_percentile(D10, 50) - 550.0) < TOL

def test_d10_p90():
    # rank = 0.9*9 = 8.1 -> 900 + 0.1*100 = 910.0
    assert abs(compute_percentile(D10, 90) - 910.0) < TOL

def test_d10_p95():
    # rank = 0.95*9 = 8.55 -> 900 + 0.55*100 = 955.0
    assert abs(compute_percentile(D10, 95) - 955.0) < TOL

def test_d10_p99():
    # rank = 0.99*9 = 8.91 -> 900 + 0.91*100 = 991.0
    assert abs(compute_percentile(D10, 99) - 991.0) < TOL

def test_d10_p100():
    assert abs(compute_percentile(D10, 100) - 1000.0) < TOL

# ── D5 values ────────────────────────────────────────────────────────────────

def test_d5_p50():
    # sorted [1,3,5,7,9]; rank = 0.5*4 = 2.0 -> data[2] = 5.0
    assert abs(compute_percentile(D5, 50) - 5.0) < TOL

def test_d5_p25():
    # rank = 0.25*4 = 1.0 -> data[1] = 3.0
    assert abs(compute_percentile(D5, 25) - 3.0) < TOL

def test_d5_p75():
    # rank = 0.75*4 = 3.0 -> data[3] = 7.0
    assert abs(compute_percentile(D5, 75) - 7.0) < TOL

def test_d5_p10():
    # rank = 0.10*4 = 0.4 -> data[0] + 0.4*(data[1]-data[0]) = 1 + 0.4*2 = 1.8
    assert abs(compute_percentile(D5, 10) - 1.8) < TOL

# ── edge cases ────────────────────────────────────────────────────────────────

def test_single_element_any_p():
    for p in [0, 25, 50, 75, 99, 100]:
        assert abs(compute_percentile(D1, p) - 42.0) < TOL, f"failed at p={p}"

def test_two_elements_p50():
    # sorted [10, 90]; rank = 0.5*1 = 0.5 -> 10 + 0.5*80 = 50.0
    assert abs(compute_percentile(D2, 50) - 50.0) < TOL

def test_two_elements_p0():
    assert abs(compute_percentile(D2, 0) - 10.0) < TOL

def test_two_elements_p100():
    assert abs(compute_percentile(D2, 100) - 90.0) < TOL

def test_empty_raises_value_error():
    with pytest.raises((ValueError, Exception)):
        compute_percentile([], 50)

def test_unsorted_input_gives_correct_result():
    shuffled = list(reversed(D10))
    assert abs(compute_percentile(shuffled, 99) - 991.0) < TOL

# ── D100 cross-check against reference ────────────────────────────────────────

def test_d100_matches_reference():
    for p in [50, 75, 90, 95, 99]:
        got = compute_percentile(D100, p)
        exp = _interp(D100, p)
        assert abs(got - exp) < TOL, (
            f"p{p}: got {got:.4f}, expected {exp:.4f} (diff {abs(got-exp):.4f})"
        )

# ── check_slo ─────────────────────────────────────────────────────────────────

def test_slo_breach_when_p99_exceeds_threshold():
    # p99 of D10 = 991.0; threshold 900 -> breach
    assert check_slo(D10, 900.0) is True

def test_slo_met_when_p99_below_threshold():
    # p99 of D10 = 991.0; threshold 1000 -> met
    assert check_slo(D10, 1000.0) is False

def test_slo_met_when_threshold_exactly_equals_p99():
    # p99 = 991.0; threshold = 991.0 -> not strictly greater -> met (False)
    assert check_slo(D10, 991.0) is False

def test_slo_on_d5():
    # p99 of sorted [1,3,5,7,9]; rank=0.99*4=3.96 -> 7+0.96*2 = 8.92
    assert check_slo(D5, 8.0) is True
    assert check_slo(D5, 9.0) is False
PYEOF

if "$PYTEST" "$TMPTEST" -v 2>&1; then
    echo
    echo "All checks passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "checks failed — fix your implementation and retry"
fi
