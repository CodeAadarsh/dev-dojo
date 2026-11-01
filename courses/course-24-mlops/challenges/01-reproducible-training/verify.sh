#!/usr/bin/env bash
# Verifier for "Reproducible Training".
# Writes a hidden pytest harness into $WORK/_judge/, runs it, prints the flag
# only when all four tests pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/01-reproducible-training"
FLAG='KUBE{reproducible_training_wins}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/train.py" ] || fail "train.py not found in $WORK — run setup.sh first"

mkdir -p "$WORK/_judge"

# ── hidden test harness ──────────────────────────────────────────────────────
cat > "$WORK/_judge/test_reproducible.py" << 'PYEOF'
import sys
import os
import pickle
import importlib.util

import numpy as np
from sklearn.datasets import make_classification

WORK = os.environ["DOJO_WORK"]
sys.path.insert(0, WORK)


def _load_train_module():
    spec = importlib.util.spec_from_file_location(
        "train_mod", os.path.join(WORK, "train.py")
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


mod = _load_train_module()


def test_train_returns_float():
    os.chdir(WORK)
    result = mod.train()
    assert isinstance(result, float), (
        f"train() must return a float accuracy, got {type(result).__name__}"
    )


def test_artifact_saved():
    os.chdir(WORK)
    mod.train()
    assert os.path.isfile(os.path.join(WORK, "model.pkl")), (
        "model.pkl not written — use pickle.dump(model, open('model.pkl', 'wb'))"
    )


def test_accuracy_threshold():
    os.chdir(WORK)
    acc = mod.train()
    assert isinstance(acc, float) and acc >= mod.THRESHOLD, (
        f"accuracy {acc:.4f} is below threshold {mod.THRESHOLD} — "
        "try LogisticRegression or RandomForestClassifier"
    )


def test_reproducible_predictions():
    os.chdir(WORK)
    # Fixed probe set independent of the training data
    X_probe, _ = make_classification(
        n_samples=200,
        n_features=20,
        n_informative=10,
        n_redundant=5,
        random_state=7,
    )
    # Run #1
    mod.train()
    with open(os.path.join(WORK, "model.pkl"), "rb") as fh:
        m1 = pickle.load(fh)
    # Run #2 — overwrites model.pkl; if non-deterministic, predictions will differ
    mod.train()
    with open(os.path.join(WORK, "model.pkl"), "rb") as fh:
        m2 = pickle.load(fh)

    assert np.array_equal(m1.predict(X_probe), m2.predict(X_probe)), (
        "Predictions differ between two train() calls — "
        "set random_state on train_test_split AND the estimator"
    )
PYEOF

# ── locate pytest ────────────────────────────────────────────────────────────
cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install scikit-learn numpy pytest"
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
