#!/usr/bin/env bash
# Verifier for "Hypothesis Test — Two-Sample t-Test".
# Regenerates the seeded samples, writes a hidden pytest suite, runs it, and
# prints the flag only when every test passes.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="03-hypothesis-test"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{hypothesis_test_two_sample_ttest}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]             || fail "work directory missing — run setup.sh first"
[ -f "$WORK/solution.py" ] || fail "solution.py not found — run setup.sh first"
[ -f "$WORK/samples.csv" ] || fail "samples.csv not found — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest numpy pandas scipy"
fi

mkdir -p _verify

cat > "_verify/test_hidden.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np
import pandas as pd
from scipy import stats
from solution import run_test

CSV = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "samples.csv")


# ── oracle ────────────────────────────────────────────────────────────────────

def _expected():
    df = pd.read_csv(CSV)
    a = df["group_a"].values
    b = df["group_b"].values
    res = stats.ttest_ind(a, b, equal_var=False)
    return {
        "statistic": float(res.statistic),
        "p_value": float(res.pvalue),
        "reject_null": bool(res.pvalue < 0.05),
        "a": a,
        "b": b,
    }


# ── tests ─────────────────────────────────────────────────────────────────────

def test_return_type():
    exp = _expected()
    result = run_test(exp["a"], exp["b"])
    assert isinstance(result, dict), f"must return dict, got {type(result)}"


def test_required_keys():
    exp = _expected()
    result = run_test(exp["a"], exp["b"])
    for key in ("statistic", "p_value", "reject_null"):
        assert key in result, f"missing key '{key}'"


def test_statistic_is_float():
    exp = _expected()
    result = run_test(exp["a"], exp["b"])
    assert isinstance(result["statistic"], float), \
        f"statistic must be float, got {type(result['statistic'])}"


def test_p_value_is_float():
    exp = _expected()
    result = run_test(exp["a"], exp["b"])
    assert isinstance(result["p_value"], float), \
        f"p_value must be float, got {type(result['p_value'])}"


def test_reject_null_is_bool():
    exp = _expected()
    result = run_test(exp["a"], exp["b"])
    assert isinstance(result["reject_null"], bool), \
        f"reject_null must be bool, got {type(result['reject_null'])}"


def test_p_value_range():
    exp = _expected()
    result = run_test(exp["a"], exp["b"])
    assert 0.0 <= result["p_value"] <= 1.0, \
        f"p_value must be in [0, 1], got {result['p_value']}"


def test_p_value_correct():
    exp = _expected()
    result = run_test(exp["a"], exp["b"])
    assert abs(result["p_value"] - exp["p_value"]) < 1e-6, \
        f"p_value mismatch: expected {exp['p_value']:.8f}, got {result['p_value']:.8f}"


def test_statistic_correct():
    exp = _expected()
    result = run_test(exp["a"], exp["b"])
    assert abs(result["statistic"] - exp["statistic"]) < 1e-6, \
        f"statistic mismatch: expected {exp['statistic']:.6f}, got {result['statistic']:.6f}"


def test_reject_null_correct():
    exp = _expected()
    result = run_test(exp["a"], exp["b"])
    assert result["reject_null"] == exp["reject_null"], \
        f"reject_null: expected {exp['reject_null']}, got {result['reject_null']}"


def test_reject_null_matches_p_value():
    exp = _expected()
    result = run_test(exp["a"], exp["b"])
    expected_decision = result["p_value"] < 0.05
    assert result["reject_null"] == expected_decision, \
        f"reject_null ({result['reject_null']}) is inconsistent with p_value ({result['p_value']:.6f}) at alpha=0.05"


def test_uses_welch_not_student():
    """Welch and Student t-tests give different statistics for unequal variances.
    The hidden oracle uses equal_var=False (Welch). If the learner uses Student
    (equal_var=True) the statistic will differ slightly."""
    exp = _expected()
    result = run_test(exp["a"], exp["b"])
    student = stats.ttest_ind(exp["a"], exp["b"], equal_var=True)
    # If result matches Student but not Welch, they used the wrong test
    welch_diff = abs(result["statistic"] - exp["statistic"])
    student_diff = abs(result["statistic"] - float(student.statistic))
    assert welch_diff < student_diff or welch_diff < 1e-6, \
        "looks like you used Student's t-test (equal_var=True) — use Welch's (equal_var=False)"


def test_different_samples_independent():
    """Verify the function works on arbitrary arrays, not just the CSV data."""
    rng = np.random.default_rng(7777)
    a2 = rng.normal(10, 2, 50)
    b2 = rng.normal(10, 2, 50)  # same distribution — should NOT reject
    result = run_test(a2, b2)
    exp_res = stats.ttest_ind(a2, b2, equal_var=False)
    assert abs(result["p_value"] - float(exp_res.pvalue)) < 1e-6, \
        "function must work on any input arrays, not just the CSV data"


def test_clearly_different_populations():
    """Two populations with very different means must reject the null."""
    rng = np.random.default_rng(1234)
    a3 = rng.normal(100, 5, 100)
    b3 = rng.normal(200, 5, 100)
    result = run_test(a3, b3)
    assert result["reject_null"] is True, \
        "means of 100 vs 200 with std=5 must clearly reject H0"
    assert result["p_value"] < 1e-10, \
        f"p_value for clearly different populations should be near 0, got {result['p_value']}"
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
