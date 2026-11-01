#!/usr/bin/env bash
# Plants the "Detect Drift" starter project.
# Idempotent — re-running overwrites source files but does not touch .venv.
set -euo pipefail

SLUG="05-detect-drift"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── generate reference and sample arrays ────────────────────────────────────
python3 - << 'PYEOF'
import os, sys
try:
    import numpy as np
    from sklearn.datasets import load_iris
except ImportError:
    print("ERROR: numpy or scikit-learn not installed. Run: pip install numpy scikit-learn")
    sys.exit(1)

rng   = np.random.default_rng(42)
work  = os.path.expanduser("~/.kube-dojo-work/05-detect-drift")

iris  = load_iris()
X     = iris.data.astype(np.float64)

# reference: random sample from training distribution
idx_ref   = rng.choice(len(X), size=120, replace=True)
reference = X[idx_ref] + rng.normal(0, 0.02, (120, 4))

# no_drift: another sample from the same distribution
idx_nd   = rng.choice(len(X), size=80, replace=True)
no_drift = X[idx_nd] + rng.normal(0, 0.02, (80, 4))

# drifted: features scaled up significantly (covariate shift)
rng2     = np.random.default_rng(99)
idx_d    = rng2.choice(len(X), size=80, replace=True)
drifted  = X[idx_d] * 1.8 + rng2.normal(2.0, 0.3, (80, 4))

np.save(os.path.join(work, "reference.npy"), reference)
np.save(os.path.join(work, "no_drift.npy"),  no_drift)
np.save(os.path.join(work, "drifted.npy"),   drifted)
print(f"reference.npy : {reference.shape}")
print(f"no_drift.npy  : {no_drift.shape}")
print(f"drifted.npy   : {drifted.shape}")
PYEOF

# ── drift.py skeleton ────────────────────────────────────────────────────────
cat > "$WORK/drift.py" << 'PYEOF'
# drift.py — implement the detect() function.
#
# You may use either approach:
#   A) PSI  — Population Stability Index across all features (sum)
#   B) KS   — Kolmogorov-Smirnov statistic per feature (max)
#
# detect() must return a dict: {"score": float, "drift": bool}
# where drift = True if score >= threshold.

import numpy as np


def detect(reference: np.ndarray, current: np.ndarray, threshold: float = 0.2) -> dict:
    """
    Compute a drift score between reference and current distributions.

    Parameters
    ----------
    reference : np.ndarray, shape (N, F)
        Baseline feature matrix (e.g. training data sample).
    current : np.ndarray, shape (M, F)
        Production feature matrix to compare against reference.
    threshold : float
        Score value at or above which drift is flagged.

    Returns
    -------
    dict with keys:
        score (float) — aggregate PSI sum or max KS statistic
        drift (bool)  — True if score >= threshold
    """
    # TODO: implement drift detection.
    # Hint A (PSI):
    #   for each feature:
    #     bin reference into 10 equal-width buckets (np.histogram)
    #     compute proportion of current samples falling in each bucket
    #     PSI_i = sum((p_current - p_ref) * ln(p_current / p_ref))
    #   total_score = sum(PSI_i for all features)
    #   threshold = 0.2 is the standard alert level
    #
    # Hint B (KS):
    #   from scipy.stats import ks_2samp
    #   scores = [ks_2samp(reference[:, i], current[:, i]).statistic for i in range(F)]
    #   total_score = max(scores)
    #   threshold = 0.1 is typical for KS
    raise NotImplementedError("detect() not implemented")
PYEOF

# ── visible sample tests ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_drift.py" << 'PYEOF'
# Visible sample tests — run locally to check your progress.
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np
from drift import detect

WORK = os.path.expanduser("~/.kube-dojo-work/05-detect-drift")
reference = np.load(os.path.join(WORK, "reference.npy"))
no_drift  = np.load(os.path.join(WORK, "no_drift.npy"))
drifted   = np.load(os.path.join(WORK, "drifted.npy"))


def test_detect_returns_dict():
    result = detect(reference, no_drift)
    assert isinstance(result, dict), "detect() must return a dict"
    assert "score" in result, "result must have a 'score' key"
    assert "drift" in result, "result must have a 'drift' key"


def test_no_drift_flagged_false():
    result = detect(reference, no_drift, threshold=0.2)
    assert result["drift"] is False, \
        f"stable traffic should not trigger drift, got score={result['score']:.4f}"


def test_drifted_flagged_true():
    result = detect(reference, drifted, threshold=0.2)
    assert result["drift"] is True, \
        f"shifted traffic must trigger drift, got score={result['score']:.4f}"
PYEOF

echo
echo "Work directory  : $WORK"
echo
echo "Task            : implement detect() in drift.py — return a dict with"
echo "                  'score' (float) and 'drift' (bool) at threshold=0.2."
echo "                  Use PSI (sum across features) or KS (max across features)."
echo
echo "Prerequisites   :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install scikit-learn pytest numpy scipy pandas"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag    : bash courses/course-24-mlops/challenges/05-detect-drift/verify.sh"
