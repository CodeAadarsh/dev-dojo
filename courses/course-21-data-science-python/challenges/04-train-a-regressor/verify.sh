#!/usr/bin/env bash
# Verifier for "Train a Regressor".
# Writes a hidden pytest suite into the work directory, runs it, prints the
# flag only when every assertion passes.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="04-train-a-regressor"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{pipeline_r2_regression}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]            || fail "work directory missing — run setup.sh first"
[ -f "$WORK/solution.py" ] || fail "solution.py not found — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest numpy scikit-learn"
fi

mkdir -p _verify

cat > "_verify/test_hidden.py" << 'PYEOF'
"""
Hidden verifier suite for 04-train-a-regressor.
All random states are fixed — results are fully deterministic.
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

# Fixed dataset — identical to what the brief describes
np.random.seed(0)
X_all, y_all = make_regression(
    n_samples=500, n_features=10, n_informative=8,
    noise=30, random_state=42
)
X_TRAIN, X_TEST, Y_TRAIN, Y_TEST = train_test_split(
    X_all, y_all, test_size=0.2, random_state=42
)

R2_THRESHOLD = 0.80


def test_returns_a_pipeline():
    pipe = build_pipeline(X_TRAIN.copy(), Y_TRAIN.copy())
    assert isinstance(pipe, Pipeline), (
        f"build_pipeline must return an sklearn Pipeline, got {type(pipe).__name__}"
    )


def test_pipeline_has_at_least_two_steps():
    pipe = build_pipeline(X_TRAIN.copy(), Y_TRAIN.copy())
    assert len(pipe.steps) >= 2, (
        f"Pipeline must have at least a scaler step and a model step, "
        f"got {len(pipe.steps)} step(s): {[s[0] for s in pipe.steps]}"
    )


def test_predict_output_shape():
    pipe = build_pipeline(X_TRAIN.copy(), Y_TRAIN.copy())
    preds = pipe.predict(X_TEST.copy())
    assert preds.shape == Y_TEST.shape, (
        f"predict() output shape {preds.shape} does not match y_test shape {Y_TEST.shape}"
    )


def test_r2_on_held_out_test_set():
    pipe = build_pipeline(X_TRAIN.copy(), Y_TRAIN.copy())
    preds = pipe.predict(X_TEST.copy())
    score = r2_score(Y_TEST, preds)
    assert score >= R2_THRESHOLD, (
        f"R² = {score:.4f} on held-out test set — need >= {R2_THRESHOLD}. "
        "Check that your pipeline includes a scaler and a well-configured regressor."
    )


def test_pipeline_uses_only_training_data_for_scaling():
    """
    Fit the pipeline on training data only, then verify it produces valid
    predictions on a completely fresh split — confirming the scaler is
    inside the pipeline and not pre-fitted on external data.
    """
    np.random.seed(0)
    X2, y2 = make_regression(
        n_samples=500, n_features=10, n_informative=8,
        noise=30, random_state=99
    )
    X2_tr, X2_te, y2_tr, y2_te = train_test_split(X2, y2, test_size=0.2, random_state=99)
    pipe2 = build_pipeline(X2_tr.copy(), y2_tr.copy())
    preds2 = pipe2.predict(X2_te.copy())
    score2 = r2_score(y2_te, preds2)
    assert score2 >= R2_THRESHOLD, (
        f"R² = {score2:.4f} on a second independent dataset — your model may be "
        "overfitting or the pipeline is not generalising correctly."
    )
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
