# Cluster and Reduce

The analytics team has 400 rows of anonymised user-behaviour telemetry — 20 features, no labels. A product manager asks:

> *"We know from domain knowledge that users fall into roughly four archetypes. Can you recover those segments automatically? I need cluster labels I can hand to the personalisation team."*

No labels. No ground truth (as far as the PM knows). Your job: scale, optionally reduce dimensionality, and cluster. The verifier has the ground-truth labels from the data generator and checks whether your recovered clusters match.

---

## Why unsupervised learning is harder than it looks

In supervised learning, the loss function (cross-entropy, MSE) tells you exactly how wrong you are. In clustering, there is no loss function during fit — you are minimising an internal criterion (inertia for k-means) that may or may not align with the clusters that are meaningful for your use case.

The three failure modes:

1. **Scale sensitivity.** k-means uses Euclidean distance. A feature with values in the thousands dominates the distance calculation over a feature in the range [0, 1]. Result: the algorithm partitions on the large-magnitude feature regardless of the true cluster structure. Fix: scale first.

2. **Curse of dimensionality.** In high-dimensional space, Euclidean distances become increasingly uniform — the ratio of max to min distance approaches 1 as dimensionality grows. All points look equally far from the centroid, and k-means struggles. Fix: reduce with PCA before clustering when dimensionality is high.

3. **Wrong k.** k-means requires you to specify the number of clusters. Use the elbow method (plot inertia vs k) or silhouette analysis to select k when ground truth is unknown.

---

## The dataset

```python
from sklearn.datasets import make_blobs
from sklearn.preprocessing import StandardScaler

X, y_true = make_blobs(
    n_samples=400, n_features=20, centers=4,
    cluster_std=1.8, random_state=42
)
```

Four latent clusters in a 20-dimensional space, each with standard deviation 1.8. The clusters are well-separated but not perfectly clean — overlapping tails mean a naively applied k-means without scaling can recover them poorly.

**What happens without scaling?**

`make_blobs` internally generates data with standard-normal entries. So all features already have comparable scale for this dataset. The interesting challenge here is getting the clustering algorithm right: correct `n_clusters`, `random_state`, and optionally PCA. The verifier uses **adjusted Rand index (ARI)** as the quality metric.

---

## Evaluation metrics for clustering

### Adjusted Rand Index (ARI)

ARI compares two label assignments: your predicted clusters and the ground truth. It counts pairs of samples that are in the same or different clusters in both assignments, adjusted for chance.

```
ARI = (RI - Expected_RI) / (max(RI) - Expected_RI)

Range: [-1, 1]
  1.0  → perfect match with ground truth
  0.0  → random labeling (no better than chance)
 <0.0  → worse than chance
```

ARI does not care about label permutations — cluster 0 in your output matching cluster 2 in ground truth is still a perfect score.

### Silhouette Score

When ground truth is not available (production scenario), silhouette score measures cluster quality internally:

```
s(i) = (b(i) - a(i)) / max(a(i), b(i))

a(i) = mean intra-cluster distance for sample i
b(i) = mean distance to nearest foreign cluster

Range: [-1, 1]
  1.0  → tight, well-separated clusters
  0.0  → sample is on or near a decision boundary
 -1.0  → sample is in the wrong cluster
```

The verifier checks **ARI ≥ 0.85** (ground truth available). As a sanity check, a good solution also has silhouette score ≥ 0.35.

---

## PCA before clustering — when and why

```
20 features
     │
     │  StandardScaler  →  zero-mean, unit-variance
     │
     ▼
  scaled (20 dim)
     │
     │  PCA(n_components=k)  →  captures top-k directions of variance
     │
     ▼
  reduced (k dim)   ←  distances are now meaningful
     │
     │  KMeans(n_clusters=4)
     │
     ▼
  cluster labels
```

PCA rotates the coordinate system to align axes with maximum variance. The first few principal components capture most of the cluster-separating signal. By discarding low-variance components (which often contain noise), you concentrate the cluster signal.

**Rule of thumb:** if 80–90% of variance is captured by the first k components (check `np.cumsum(pca.explained_variance_ratio_)`), use those k components for clustering.

For this dataset, the first 10 components capture ≈90% of variance. Using PCA(n_components=10) before KMeans typically improves ARI from ~0.90 to ~0.97.

---

## The `cluster()` function contract

The verifier imports `cluster(X)` from your `solution.py`:

- **Input:** `X` — NumPy array, shape `(400, 20)`, unscaled.
- **Output:** NumPy array of integer cluster labels, shape `(400,)`.
- Labels must be integers 0 through k-1 (or any integer labels — ARI is label-permutation-invariant).

You are free to use any combination of scaling, PCA, and clustering inside. The verifier does not inspect your pipeline internals — it only checks `adjusted_rand_score(y_true, cluster(X))`.

---

## Prerequisites

```bash
cd ~/.kube-dojo-work/06-cluster-and-reduce
python3 -m venv .venv && . .venv/bin/activate
pip install pytest numpy scikit-learn
```

## Work directory

`setup.sh` plants:

```
~/.kube-dojo-work/06-cluster-and-reduce/
├── solution.py          # implement cluster(X) here
└── tests/
    └── test_sample.py   # two visible tests you can run locally
```

## Mission

Implement `cluster(X)` in `solution.py`:

- **Input:** `X` — a NumPy array of shape `(400, 20)`, unscaled.
- **Output:** a NumPy array of integer cluster labels, shape `(400,)`.
- The verifier asserts `adjusted_rand_score(y_true, cluster(X)) >= 0.85`.

## Verify

```bash
bash courses/course-21-data-science-python/challenges/06-cluster-and-reduce/verify.sh
```

ARI ≥ 0.85 against ground-truth labels → flag printed.
