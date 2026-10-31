#!/usr/bin/env bash
# Verifier for "Classify without Leakage".
# Writes a hidden pytest suite, runs it against solution.py, prints the flag
# only when all assertions pass.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="05-classify-without-leakage"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{no_leakage_pipeline_f1}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]            || fail "work directory missing — run setup.sh first"
[ -f "$WORK/solution.py" ] || fail "solution.py not found — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest numpy pandas scikit-learn"
fi

mkdir -p _verify

cat > "_verify/test_hidden.py" << 'PYEOF'
"""
Hidden verifier suite for 05-classify-without-leakage.
All random states are fixed — results are fully deterministic.
"""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np
import pandas as pd
from sklearn.datasets import make_classification
from sklearn.model_selection import train_test_split
from sklearn.metrics import f1_score
from sklearn.pipeline import Pipeline
from solution import build_pipeline

# Fixed dataset ─ identical to what brief and setup describe
np.random.seed(0)
X_RAW, Y_ALL = make_classification(
    n_samples=600, n_features=15, n_informative=10,
    n_redundant=2, random_state=42
)
X_ALL = pd.DataFrame(X_RAW, columns=[f'f{i}' for i in range(15)])
X_ALL['leaky'] = Y_ALL + np.random.default_rng(99).normal(0, 0.05, len(Y_ALL))

# X_TRAIN_FULL has the 'leaky' column; X_TEST_CLEAN does not
X_TRAIN_FULL, X_TEST_BASE, Y_TRAIN, Y_TEST = train_test_split(
    X_ALL, Y_ALL, test_size=0.2, random_state=42
)
X_TEST_CLEAN = X_TEST_BASE.drop(columns=['leaky'])

F1_THRESHOLD = 0.80


def test_returns_a_pipeline():
    pipe = build_pipeline(X_TRAIN_FULL.copy(), Y_TRAIN.copy())
    assert isinstance(pipe, Pipeline), (
        f"build_pipeline must return an sklearn Pipeline, got {type(pipe).__name__}"
    )


def test_pipeline_predicts_without_leaky_column():
    """
    Core leakage check: predict must succeed on data with no 'leaky' column.
    If the pipeline was built to depend on 'leaky', this raises.
    """
    pipe = build_pipeline(X_TRAIN_FULL.copy(), Y_TRAIN.copy())
    try:
        y_pred = pipe.predict(X_TEST_CLEAN.copy())
    except Exception as exc:
        assert False, (
            f"pipeline.predict() raised {type(exc).__name__} when 'leaky' column "
            f"is absent from X_test: {exc}\n"
            "Drop 'leaky' inside build_pipeline using ColumnTransformer or "
            "X_train.drop(columns=['leaky']) before fitting."
        )
    assert y_pred.shape == Y_TEST.shape, (
        f"predict output shape {y_pred.shape} != y_test shape {Y_TEST.shape}"
    )


def test_f1_on_clean_test_set():
    pipe = build_pipeline(X_TRAIN_FULL.copy(), Y_TRAIN.copy())
    y_pred = pipe.predict(X_TEST_CLEAN.copy())
    score = f1_score(Y_TEST, y_pred, average='weighted')
    assert score >= F1_THRESHOLD, (
        f"weighted F1 = {score:.4f} on clean test set — need >= {F1_THRESHOLD}. "
        "Ensure preprocessing is inside the Pipeline and the classifier is "
        "reasonably configured (LogisticRegression max_iter=1000, or RandomForest)."
    )


def test_f1_on_second_split():
    """Verify the pipeline generalises — not overfitted to the exact split."""
    np.random.seed(0)
    X2_raw, y2 = make_classification(
        n_samples=600, n_features=15, n_informative=10,
        n_redundant=2, random_state=7
    )
    X2 = pd.DataFrame(X2_raw, columns=[f'f{i}' for i in range(15)])
    X2['leaky'] = y2 + np.random.default_rng(77).normal(0, 0.05, len(y2))
    X2_tr, X2_te, y2_tr, y2_te = train_test_split(X2, y2, test_size=0.2, random_state=7)
    X2_te_clean = X2_te.drop(columns=['leaky'])

    pipe2 = build_pipeline(X2_tr.copy(), y2_tr.copy())
    y2_pred = pipe2.predict(X2_te_clean.copy())
    score2 = f1_score(y2_te, y2_pred, average='weighted')
    assert score2 >= F1_THRESHOLD, (
        f"weighted F1 = {score2:.4f} on second independent dataset — "
        "the pipeline is not generalising. Check for hardcoded assumptions."
    )


def test_pipeline_has_multiple_steps():
    pipe = build_pipeline(X_TRAIN_FULL.copy(), Y_TRAIN.copy())
    assert len(pipe.steps) >= 2, (
        f"Pipeline should have a preprocessing step and a classifier step, "
        f"got {len(pipe.steps)} step(s)."
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
