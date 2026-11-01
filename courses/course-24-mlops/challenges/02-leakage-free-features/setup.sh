#!/usr/bin/env bash
# Plants the "Leakage-Free Feature Pipeline" starter into the work directory.
# Idempotent — re-running overwrites features.py but does not touch .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/02-leakage-free-features"
mkdir -p "$WORK"

# ── features.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/features.py" << 'PYEOF'
# features.py — feature pipeline skeleton
# Study build_features_leaky() to understand the two bugs, then fix them in
# build_features().
import numpy as np
import pandas as pd
from sklearn.datasets import make_classification
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler

SEED = 42
N_FEATURES = 10
LEAKY_COLS = ["future_score"]   # column(s) derived from the target — must be dropped


def make_raw_df() -> pd.DataFrame:
    """Fixed seeded dataset with an obvious leaky column — do not modify."""
    np.random.seed(SEED)
    X, y = make_classification(
        n_samples=500,
        n_features=N_FEATURES,
        n_informative=5,
        n_redundant=2,
        random_state=SEED,
    )
    df = pd.DataFrame(X, columns=[f"f{i}" for i in range(N_FEATURES)])
    df["future_score"] = y * 10.0 + np.random.normal(0, 0.1, len(y))
    df["target"] = y.astype(int)
    return df


def build_features_leaky(df: pd.DataFrame):
    """
    LEAKY baseline — fits scaler on ALL rows before splitting.
    Do NOT fix this function: study it and identify both bugs,
    then implement build_features() correctly below.
    """
    X = df.drop(columns=["target"]).values   # future_score still present!
    y = df["target"].values
    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)       # fit on full dataset — leakage!
    X_train, X_test, y_train, y_test = train_test_split(
        X_scaled, y, test_size=0.2, random_state=SEED
    )
    return X_train, X_test, y_train, y_test, scaler


def build_features(
    df: pd.DataFrame,
    test_size: float = 0.2,
    random_state: int = SEED,
):
    """
    Implement a leakage-free pipeline:
      1. Drop all columns in LEAKY_COLS before any split.
      2. Separate X (all remaining non-target columns) and y ("target").
      3. Split X and y into train and test BEFORE fitting any transform.
      4. Fit StandardScaler on X_train ONLY.
      5. Transform both X_train and X_test with the fitted scaler.
      6. Return (X_train_scaled, X_test_scaled, y_train, y_test, scaler).

    The verifier checks:
      - X_train / X_test have exactly N_FEATURES columns (LEAKY_COLS dropped).
      - scaler.mean_ matches train-only statistics, not full-dataset statistics.
      - Train + test row counts equal the original dataset size.
    """
    raise NotImplementedError("implement build_features()")
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement build_features() in features.py so all four"
echo "                 verifier checks pass."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install scikit-learn numpy pandas pytest"
echo
echo "Quick smoke-test while developing:"
echo "  cd $WORK && python3 -c \\"
echo "    'from features import make_raw_df, build_features; df=make_raw_df(); print(build_features(df)[0].shape)'"
echo
echo "Verify + flag  :"
echo "  bash courses/course-24-mlops/challenges/02-leakage-free-features/verify.sh"
