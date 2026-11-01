#!/usr/bin/env bash
# Verifier for "Leakage-Free Feature Pipeline".
# Writes a hidden pytest harness into $WORK/_judge/, runs it, prints the flag
# only when all four tests pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/02-leakage-free-features"
FLAG='KUBE{train_only_no_leakage}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/features.py" ] || fail "features.py not found — run setup.sh first"

mkdir -p "$WORK/_judge"

# ── hidden test harness ──────────────────────────────────────────────────────
cat > "$WORK/_judge/test_leakage_free.py" << 'PYEOF'
import sys
import os
import importlib.util

import numpy as np
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler

WORK = os.environ["DOJO_WORK"]
sys.path.insert(0, WORK)


def _load_module():
    spec = importlib.util.spec_from_file_location(
        "features_mod", os.path.join(WORK, "features.py")
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


mod = _load_module()


def test_leaky_cols_dropped():
    df = mod.make_raw_df()
    X_tr, X_te, y_tr, y_te, scaler = mod.build_features(df)
    assert X_tr.shape[1] == mod.N_FEATURES, (
        f"X_train has {X_tr.shape[1]} columns; expected {mod.N_FEATURES} "
        f"(LEAKY_COLS {mod.LEAKY_COLS} must be dropped before returning)"
    )
    assert X_te.shape[1] == mod.N_FEATURES, (
        f"X_test has {X_te.shape[1]} columns; expected {mod.N_FEATURES}"
    )


def test_scaler_fit_on_train_only():
    df = mod.make_raw_df()
    # Reproduce independently: what a correct implementation's X_train looks like
    X_clean = df.drop(columns=["target"] + mod.LEAKY_COLS).values
    y = df["target"].values
    X_tr_raw, _, _, _ = train_test_split(
        X_clean, y, test_size=0.2, random_state=mod.SEED
    )
    expected_mean = X_tr_raw.mean(axis=0)

    _, _, _, _, scaler = mod.build_features(df)
    assert np.allclose(scaler.mean_, expected_mean, atol=1e-6), (
        "scaler.mean_ does not match train-only statistics — "
        "call scaler.fit(X_train) AFTER splitting, not scaler.fit_transform(X)"
    )


def test_scaler_not_fit_on_full_data():
    df = mod.make_raw_df()
    X_clean = df.drop(columns=["target"] + mod.LEAKY_COLS).values
    full_mean = X_clean.mean(axis=0)

    _, _, _, _, scaler = mod.build_features(df)
    if np.allclose(scaler.mean_, full_mean, atol=1e-6):
        raise AssertionError(
            "scaler.mean_ matches full-dataset statistics — "
            "the scaler was fit before the split (preprocessing leakage)"
        )


def test_row_counts_consistent():
    df = mod.make_raw_df()
    X_tr, X_te, y_tr, y_te, _ = mod.build_features(df)
    n = len(df)
    assert len(X_tr) + len(X_te) == n, (
        f"Row count mismatch: {len(X_tr)} + {len(X_te)} != {n}"
    )
    assert len(y_tr) == len(X_tr), "y_train length != X_train length"
    assert len(y_te) == len(X_te), "y_test length != X_test length"
PYEOF

# ── locate pytest ────────────────────────────────────────────────────────────
cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install scikit-learn numpy pandas pytest"
fi

# ── run ──────────────────────────────────────────────────────────────────────
if DOJO_WORK="$WORK" $PYTEST _judge/ -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix your implementation and retry"
fi
