#!/usr/bin/env bash
# Plants the "Reproducible Training" starter into the work directory.
# Idempotent — re-running overwrites train.py but does not touch .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/01-reproducible-training"
mkdir -p "$WORK"

# ── train.py skeleton ────────────────────────────────────────────────────────
cat > "$WORK/train.py" << 'PYEOF'
# train.py — reproducible training skeleton
# Mission: implement train() so that:
#   1. The trained model is saved to 'model.pkl' in the current directory.
#   2. train() returns the test-set accuracy as a float.
#   3. Two consecutive train() calls produce byte-identical predictions.
import numpy as np
import pickle
from sklearn.datasets import make_classification
from sklearn.model_selection import train_test_split

SEED = 42
THRESHOLD = 0.80


def make_dataset():
    """Seeded dataset — do not modify this function."""
    X, y = make_classification(
        n_samples=1000,
        n_features=20,
        n_informative=10,
        n_redundant=5,
        random_state=SEED,
    )
    return X, y


def train() -> float:
    """
    Train a classifier on make_dataset(), save model.pkl in cwd, return test accuracy.

    Requirements:
      - Use a fixed random_state everywhere the API accepts one.
      - Test accuracy must be >= THRESHOLD (0.80).
      - Save: pickle.dump(model, open('model.pkl', 'wb'))
    """
    raise NotImplementedError("implement train()")
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement train() in train.py so all four verifier"
echo "                 checks pass (artifact saved, accuracy >= 0.80,"
echo "                 float returned, identical predictions across runs)."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install scikit-learn numpy pytest"
echo
echo "Quick smoke-test while developing:"
echo "  cd $WORK && python3 -c 'from train import train; print(train())'"
echo
echo "Verify + flag  :"
echo "  bash courses/course-24-mlops/challenges/01-reproducible-training/verify.sh"
