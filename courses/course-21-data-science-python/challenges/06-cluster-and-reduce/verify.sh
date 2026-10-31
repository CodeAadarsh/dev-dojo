#!/usr/bin/env bash
# Verifier for "Cluster and Reduce".
# Writes a hidden pytest suite, runs it against solution.py, prints the flag
# only when all assertions pass.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="06-cluster-and-reduce"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{kmeans_ari_silhouette}'

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
Hidden verifier suite for 06-cluster-and-reduce.
All random states are fixed — results are fully deterministic.
"""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np
from sklearn.datasets import make_blobs
from sklearn.metrics import adjusted_rand_score, silhouette_score
from solution import cluster

# Fixed dataset — identical to what brief and setup describe
np.random.seed(0)
X_DATA, Y_TRUE = make_blobs(
    n_samples=400, n_features=20, centers=4,
    cluster_std=1.8, random_state=42
)

ARI_THRESHOLD = 0.85
SILHOUETTE_THRESHOLD = 0.30


def test_output_shape():
    labels = cluster(X_DATA.copy())
    labels = np.array(labels)
    assert labels.shape == (400,), (
        f"cluster() must return shape (400,), got {labels.shape}"
    )


def test_output_dtype_is_integer():
    labels = np.array(cluster(X_DATA.copy()))
    assert labels.dtype.kind in ('i', 'u'), (
        f"cluster() must return integer labels, got dtype {labels.dtype}"
    )


def test_number_of_unique_labels():
    labels = np.array(cluster(X_DATA.copy()))
    n_unique = len(set(labels))
    assert 2 <= n_unique <= 8, (
        f"Expected between 2 and 8 unique cluster labels, got {n_unique}. "
        "Did you set n_clusters=4 for k-means?"
    )


def test_ari_against_ground_truth():
    labels = np.array(cluster(X_DATA.copy()))
    ari = adjusted_rand_score(Y_TRUE, labels)
    assert ari >= ARI_THRESHOLD, (
        f"ARI = {ari:.4f} against ground truth — need >= {ARI_THRESHOLD}.\n"
        "Tips:\n"
        "  1. Scale with StandardScaler before clustering.\n"
        "  2. Use KMeans(n_clusters=4, random_state=42, n_init=10).\n"
        "  3. Optionally add PCA(n_components=10, random_state=42) between "
        "scaler and KMeans for higher ARI."
    )


def test_silhouette_sanity():
    """
    Internal quality check — ensures clusters are not degenerate
    (all samples assigned to one cluster, etc.).
    """
    labels = np.array(cluster(X_DATA.copy()))
    n_unique = len(set(labels))
    if n_unique < 2:
        assert False, "silhouette_score requires at least 2 clusters"
    sil = silhouette_score(X_DATA, labels, random_state=42)
    assert sil >= SILHOUETTE_THRESHOLD, (
        f"Silhouette score = {sil:.4f} — clusters are not well-separated "
        f"(need >= {SILHOUETTE_THRESHOLD}). Check that scaling is applied."
    )


def test_ari_on_second_dataset():
    """Verify the approach generalises to a different random_state."""
    np.random.seed(0)
    X2, y2 = make_blobs(
        n_samples=400, n_features=20, centers=4,
        cluster_std=1.8, random_state=7
    )
    labels2 = np.array(cluster(X2.copy()))
    ari2 = adjusted_rand_score(y2, labels2)
    assert ari2 >= ARI_THRESHOLD, (
        f"ARI = {ari2:.4f} on second dataset — your cluster() function does not "
        "generalise. Avoid hardcoded assumptions about the exact data layout."
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
