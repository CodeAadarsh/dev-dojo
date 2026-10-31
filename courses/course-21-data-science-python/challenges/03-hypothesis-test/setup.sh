#!/usr/bin/env bash
# Plants the "Hypothesis Test" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="03-hypothesis-test"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── generate seeded samples.csv (stdlib only — numpy not required here) ───────
python3 -I - "$WORK" << 'PYEOF'
import sys, csv, random, math

# Box-Muller transform to generate normally-distributed values using stdlib only.
def normal_samples(mu, sigma, n, seed):
    rng = random.Random(seed)
    result = []
    while len(result) < n:
        u1 = rng.random()
        u2 = rng.random()
        z0 = math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2)
        z1 = math.sqrt(-2.0 * math.log(u1)) * math.sin(2.0 * math.pi * u2)
        result.append(mu + sigma * z0)
        if len(result) < n:
            result.append(mu + sigma * z1)
    return result[:n]

# Seeds chosen so the difference is statistically significant (t-test rejects H0).
group_a = normal_samples(50.0, 8.0, 80, seed=42)
group_b = normal_samples(46.0, 9.0, 80, seed=43)

out_path = sys.argv[1] + "/samples.csv"
with open(out_path, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["group_a", "group_b"])
    for a, b in zip(group_a, group_b):
        w.writerow([round(a, 6), round(b, 6)])

print(f"Wrote 80 observations per group to {out_path}")
PYEOF

# ── solution.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — two-sample t-test challenge
#
# You are given two 1-D NumPy arrays: a (Group A) and b (Group B).
# Run an independent two-sample Welch's t-test (equal_var=False) and return
# a dict with the t-statistic, the two-tailed p-value, and the reject-null
# decision at alpha=0.05.
#
# Null hypothesis  H0: mean(a) == mean(b)
# Alternative      H1: mean(a) != mean(b)  (two-tailed)
# Alpha            0.05
#
# Return: {"statistic": float, "p_value": float, "reject_null": bool}

import numpy as np


def run_test(a: np.ndarray, b: np.ndarray) -> dict:
    """Run a two-sample Welch t-test on arrays a and b.

    Args:
        a: 1-D array of floats for group A.
        b: 1-D array of floats for group B.

    Returns:
        dict with keys:
            "statistic"   (float)  — the t-statistic
            "p_value"     (float)  — two-tailed p-value
            "reject_null" (bool)   — True if p_value < 0.05
    """
    # TODO: implement using scipy.stats.ttest_ind
    raise NotImplementedError("implement run_test()")
PYEOF

# ── visible sample tests ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np
import pandas as pd
from solution import run_test

CSV = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "samples.csv")


def test_return_type():
    df = pd.read_csv(CSV)
    result = run_test(df["group_a"].values, df["group_b"].values)
    assert isinstance(result, dict), f"run_test must return a dict, got {type(result)}"
    for key in ("statistic", "p_value", "reject_null"):
        assert key in result, f"missing key '{key}' in result dict"


def test_reject_null_is_bool():
    df = pd.read_csv(CSV)
    result = run_test(df["group_a"].values, df["group_b"].values)
    assert isinstance(result["reject_null"], bool), \
        f"reject_null must be a Python bool, got {type(result['reject_null'])}"
PYEOF

echo
echo "Work directory   : $WORK"
echo
echo "Task             : implement run_test() in solution.py using scipy.stats.ttest_ind"
echo "                   so all hidden tests pass."
echo
echo "Prerequisites    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate && pip install pytest numpy pandas scipy"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag    : bash courses/course-21-data-science-python/challenges/$SLUG/verify.sh"
