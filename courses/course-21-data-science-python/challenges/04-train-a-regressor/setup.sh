#!/usr/bin/env bash
# Plants the "Train a Regressor" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="04-train-a-regressor"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── solution.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — train a regressor
#
# Context
# -------
# The verifier generates a regression dataset with:
#
#   X, y = make_regression(
#       n_samples=500, n_features=10, n_informative=8,
#       noise=30, random_state=42
#   )
#   X_train, X_test, y_train, y_test = train_test_split(
#       X, y, test_size=0.2, random_state=42
#   )
#
# It then calls build_pipeline(X_train, y_train) and asserts:
#   r2_score(y_test, pipeline.predict(X_test)) >= 0.80
#
# Requirements
# ------------
# 1. The Pipeline MUST contain a scaler (StandardScaler, MinMaxScaler, etc.)
# 2. The Pipeline MUST contain a regression estimator
# 3. The Pipeline MUST be fitted (call .fit() before returning)
# 4. Return the fitted Pipeline object — the verifier calls .predict() on it

from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import Ridge   # swap for any regressor you prefer


def build_pipeline(X_train, y_train):
    """
    Build and fit a regression Pipeline.

    Parameters
    ----------
    X_train : np.ndarray, shape (n_samples, 10)
    y_train : np.ndarray, shape (n_samples,)

    Returns
    -------
    fitted sklearn Pipeline
    """
    # TODO: replace this stub with your implementation.
    #
    # Minimum skeleton (not yet tuned):
    #   pipe = Pipeline([
    #       ('scaler', StandardScaler()),
    #       ('model',  Ridge()),
    #   ])
    #   pipe.fit(X_train, y_train)
    #   return pipe
    raise NotImplementedError("implement build_pipeline")
PYEOF

# ── tests/test_sample.py — two visible smoke tests ───────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
"""
Visible smoke tests for 04-train-a-regressor.

These run with the same API as the hidden verifier but on a smaller dataset.
All hidden tests are structurally identical — they use n_samples=500
and a stricter threshold (R2 >= 0.80).
"""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np
from sklearn.datasets import make_regression
from sklearn.model_selection import train_test_split
from sklearn.metrics import r2_score
from sklearn.pipeline import Pipeline
from solution import build_pipeline


def test_build_pipeline_returns_a_pipeline():
    X, y = make_regression(n_samples=100, n_features=5, noise=10, random_state=0)
    X_tr, X_te, y_tr, y_te = train_test_split(X, y, test_size=0.2, random_state=0)
    pipe = build_pipeline(X_tr, y_tr)
    assert isinstance(pipe, Pipeline), (
        f"build_pipeline must return an sklearn Pipeline, got {type(pipe)}"
    )


def test_pipeline_can_predict_and_scores_above_zero():
    X, y = make_regression(n_samples=200, n_features=8, n_informative=6,
                            noise=20, random_state=1)
    X_tr, X_te, y_tr, y_te = train_test_split(X, y, test_size=0.2, random_state=1)
    pipe = build_pipeline(X_tr, y_tr)
    preds = pipe.predict(X_te)
    assert preds.shape == y_te.shape, (
        f"predict output shape {preds.shape} does not match y_test shape {y_te.shape}"
    )
    score = r2_score(y_te, preds)
    # Loose threshold for the smoke test — hidden verifier uses 0.80
    assert score > 0.0, (
        f"R2 = {score:.3f} — something is wrong with the model (even a naive "
        "linear fit should beat 0.0 on this dataset)"
    )
PYEOF

echo
echo "Work directory   : $WORK"
echo
echo "Task             : implement build_pipeline(X_train, y_train) in solution.py"
echo "                   so the hidden test asserts r2_score(y_test, pipe.predict(X_test)) >= 0.80"
echo
echo "Prerequisites    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest numpy scikit-learn"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag    : bash courses/course-21-data-science-python/challenges/$SLUG/verify.sh"
