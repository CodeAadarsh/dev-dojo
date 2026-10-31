#!/usr/bin/env bash
# Plants the "Classify without Leakage" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="05-classify-without-leakage"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── solution.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — classify without leakage
#
# The verifier generates data as follows:
#
#   X_raw, y = make_classification(
#       n_samples=600, n_features=15, n_informative=10,
#       n_redundant=2, random_state=42
#   )
#   X = pd.DataFrame(X_raw, columns=[f'f{i}' for i in range(15)])
#   X['leaky'] = y + np.random.default_rng(99).normal(0, 0.05, len(y))
#
# It calls build_pipeline(X_train_with_leaky, y_train) where X_train is a
# DataFrame that includes the 'leaky' column.
#
# It then evaluates with:
#   pipeline.predict(X_test_clean)   # X_test_clean has NO 'leaky' column
#   f1_score(y_test, y_pred, average='weighted') >= 0.80
#
# Your pipeline MUST:
#   1. Internally ignore/drop the 'leaky' column
#      (so predict works on data without it)
#   2. Apply preprocessing INSIDE the pipeline (not before)
#   3. Achieve weighted F1 >= 0.80 on the clean test set

import numpy as np
import pandas as pd
from sklearn.pipeline import Pipeline
from sklearn.compose import ColumnTransformer
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import LogisticRegression


# ─────────────────────────────────────────────────────────────────────────────
# STUDY THIS — it demonstrates both leakage bugs. Do NOT copy it.
# ─────────────────────────────────────────────────────────────────────────────
def show_bad_example():
    """
    BAD CODE — two leakage bugs:
      1. 'leaky' column is derived from y (not available in production)
      2. StandardScaler is fit on all data before the train/test split
    """
    from sklearn.datasets import make_classification
    from sklearn.model_selection import train_test_split
    from sklearn.metrics import f1_score

    X_raw, y = make_classification(
        n_samples=600, n_features=15, n_informative=10,
        n_redundant=2, random_state=42
    )
    X = pd.DataFrame(X_raw, columns=[f'f{i}' for i in range(15)])

    # ⚠  BUG 1: leaky feature — directly correlated with y
    rng = np.random.default_rng(99)
    X['leaky'] = y + rng.normal(0, 0.05, len(y))

    # ⚠  BUG 2: preprocessing leakage — scaler fit on all rows before split
    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)   # test statistics bleed into scaler!

    X_train, X_test, y_train, y_test = train_test_split(
        X_scaled, y, test_size=0.2, random_state=42
    )
    from sklearn.linear_model import LogisticRegression as LR
    model = LR(max_iter=1000, random_state=42)
    model.fit(X_train, y_train)
    # This looks great (~0.98 F1) but will fail in production where 'leaky'
    # does not exist and the scaler's stats were computed on unseen data.
    return f1_score(y_test, model.predict(X_test), average='weighted')


# ─────────────────────────────────────────────────────────────────────────────
# YOUR IMPLEMENTATION — fix the two bugs
# ─────────────────────────────────────────────────────────────────────────────
def build_pipeline(X_train, y_train):
    """
    Build and fit a leak-free classification Pipeline.

    Parameters
    ----------
    X_train : pd.DataFrame with columns ['f0'...'f14', 'leaky']
    y_train : np.ndarray, shape (n_samples,)

    Returns
    -------
    fitted sklearn Pipeline that:
      - does NOT use the 'leaky' column
      - applies preprocessing inside the Pipeline
      - achieves weighted F1 >= 0.80 on the held-out clean test set
    """
    # TODO: implement this function.
    #
    # Strategy:
    #   1. Identify the feature columns to use (exclude 'leaky')
    #   2. Build a ColumnTransformer that scales only those columns
    #   3. Wrap in a Pipeline with a classifier
    #   4. Call pipe.fit(X_train, y_train) and return the fitted pipe
    #
    # Skeleton (not yet complete):
    #   feature_cols = [c for c in X_train.columns if c != 'leaky']
    #   preprocessor = ColumnTransformer([('scale', StandardScaler(), feature_cols)])
    #   pipe = Pipeline([('prep', preprocessor), ('model', LogisticRegression(max_iter=1000, random_state=42))])
    #   pipe.fit(X_train, y_train)
    #   return pipe
    raise NotImplementedError("implement build_pipeline")
PYEOF

# ── tests/test_sample.py ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
"""
Visible smoke tests for 05-classify-without-leakage.

The hidden verifier:
  - passes X_train that includes the 'leaky' column
  - evaluates pipeline.predict() on X_test that does NOT have 'leaky'
  - asserts f1_score >= 0.80 (weighted)
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


def _make_data():
    X_raw, y = make_classification(
        n_samples=600, n_features=15, n_informative=10,
        n_redundant=2, random_state=42
    )
    X = pd.DataFrame(X_raw, columns=[f'f{i}' for i in range(15)])
    X['leaky'] = y + np.random.default_rng(99).normal(0, 0.05, len(y))
    return X, y


def test_pipeline_predicts_on_data_without_leaky_column():
    """
    The pipeline must work when 'leaky' is absent from X_test.
    If the pipeline depends on 'leaky', this will raise a KeyError/ValueError.
    """
    X, y = _make_data()
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42
    )
    pipe = build_pipeline(X_train, y_train)
    assert isinstance(pipe, Pipeline), f"expected Pipeline, got {type(pipe)}"
    # Remove leaky from test — simulates production
    X_test_clean = X_test.drop(columns=['leaky'])
    try:
        preds = pipe.predict(X_test_clean)
    except Exception as e:
        raise AssertionError(
            f"pipeline.predict() raised {type(e).__name__}: {e}\n"
            "The pipeline must not depend on the 'leaky' column."
        )
    assert preds.shape == y_test.shape


def test_f1_above_threshold():
    X, y = _make_data()
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42
    )
    pipe = build_pipeline(X_train, y_train)
    X_test_clean = X_test.drop(columns=['leaky'])
    preds = pipe.predict(X_test_clean)
    score = f1_score(y_test, preds, average='weighted')
    # Loose threshold for smoke test (hidden verifier uses 0.80)
    assert score > 0.5, (
        f"weighted F1 = {score:.3f} — too low. Ensure leaky column is dropped "
        "and preprocessing is inside the Pipeline."
    )
PYEOF

echo
echo "Work directory   : $WORK"
echo
echo "Task             : implement build_pipeline(X_train, y_train) in solution.py"
echo "                   - X_train includes a 'leaky' column derived from y"
echo "                   - your pipeline must NOT use 'leaky'"
echo "                   - preprocessing must be INSIDE the Pipeline"
echo "                   - verifier evaluates on X_test with no 'leaky' column"
echo "                   - assert f1_score(y_test, pipe.predict(X_test_clean), average='weighted') >= 0.80"
echo
echo "Prerequisites    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest numpy pandas scikit-learn"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag    : bash courses/course-21-data-science-python/challenges/$SLUG/verify.sh"
