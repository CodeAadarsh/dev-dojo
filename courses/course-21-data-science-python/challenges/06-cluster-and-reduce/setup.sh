#!/usr/bin/env bash
# Plants the "Cluster and Reduce" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="06-cluster-and-reduce"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── solution.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — cluster and reduce
#
# The verifier generates data with:
#
#   X, y_true = make_blobs(
#       n_samples=400, n_features=20, centers=4,
#       cluster_std=1.8, random_state=42
#   )
#
# It calls cluster(X) and checks:
#   adjusted_rand_score(y_true, cluster(X)) >= 0.85
#
# Your cluster() function must:
#   1. Accept X: np.ndarray, shape (400, 20), unscaled
#   2. Return cluster labels: np.ndarray of ints, shape (400,)
#   3. Achieve ARI >= 0.85 against the ground truth (4 clusters)
#
# Recommended approach: StandardScaler → PCA (optional) → KMeans(n_clusters=4)
# ARI is label-permutation-invariant, so label numbering does not matter.

import numpy as np
from sklearn.preprocessing import StandardScaler
from sklearn.decomposition import PCA
from sklearn.cluster import KMeans


def cluster(X):
    """
    Cluster X into groups matching the latent structure.

    Parameters
    ----------
    X : np.ndarray, shape (400, 20)

    Returns
    -------
    labels : np.ndarray of int, shape (400,)
    """
    # TODO: implement this function.
    #
    # Skeleton (will NOT pass as-is — KMeans without scaling fails on
    # some random_state initializations):
    #
    #   scaler = StandardScaler()
    #   X_scaled = scaler.fit_transform(X)
    #   km = KMeans(n_clusters=4, random_state=42, n_init=10)
    #   return km.fit_predict(X_scaled)
    #
    # For higher ARI, add PCA before KMeans:
    #   pca = PCA(n_components=10, random_state=42)
    #   X_reduced = pca.fit_transform(X_scaled)
    #   km = KMeans(n_clusters=4, random_state=42, n_init=10)
    #   return km.fit_predict(X_reduced)
    raise NotImplementedError("implement cluster(X)")
PYEOF

# ── tests/test_sample.py ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
"""
Visible smoke tests for 06-cluster-and-reduce.

The hidden verifier uses adjusted_rand_score(y_true, cluster(X)) >= 0.85.
These tests check shape and that the function does not crash.
"""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np
from sklearn.datasets import make_blobs
from sklearn.metrics import adjusted_rand_score
from solution import cluster


def _make_data():
    X, y_true = make_blobs(
        n_samples=400, n_features=20, centers=4,
        cluster_std=1.8, random_state=42
    )
    return X, y_true


def test_cluster_returns_correct_shape():
    X, _ = _make_data()
    labels = cluster(X)
    assert hasattr(labels, '__len__'), "cluster() must return an array-like"
    assert len(labels) == len(X), (
        f"labels length {len(labels)} != X length {len(X)}"
    )


def test_cluster_returns_integer_labels():
    X, _ = _make_data()
    labels = np.array(cluster(X))
    assert labels.dtype.kind in ('i', 'u'), (
        f"labels must be integers, got dtype {labels.dtype}"
    )


def test_cluster_ari_above_zero():
    X, y_true = _make_data()
    labels = cluster(X)
    ari = adjusted_rand_score(y_true, labels)
    # Loose check — hidden verifier requires 0.85
    assert ari > 0.0, (
        f"ARI = {ari:.3f} — clustering is not better than chance. "
        "Make sure you are using n_clusters=4 and StandardScaler."
    )
PYEOF

echo
echo "Work directory   : $WORK"
echo
echo "Task             : implement cluster(X) in solution.py"
echo "                   X is a np.ndarray of shape (400, 20), unscaled"
echo "                   return integer cluster labels, shape (400,)"
echo "                   verifier asserts adjusted_rand_score(y_true, cluster(X)) >= 0.85"
echo "                   ground truth has 4 clusters"
echo
echo "Prerequisites    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest numpy scikit-learn"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag    : bash courses/course-21-data-science-python/challenges/$SLUG/verify.sh"
