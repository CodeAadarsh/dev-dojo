# Solution — Cluster and Reduce

## The implementation

```python
import numpy as np
from sklearn.preprocessing import StandardScaler
from sklearn.decomposition import PCA
from sklearn.cluster import KMeans


def cluster(X):
    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)

    pca = PCA(n_components=10, random_state=42)
    X_reduced = pca.fit_transform(X_scaled)

    km = KMeans(n_clusters=4, random_state=42, n_init=10)
    return km.fit_predict(X_reduced)
```

On the verifier's dataset this achieves ARI ≈ 0.97.

## Why each step is required

**`StandardScaler()`**

k-means minimises:

```
J = Σ_i Σ_{x ∈ C_i} ‖x - μ_i‖²
```

This is a sum of Euclidean distances. If feature 3 has values in [0, 1000] and feature 7 has values in [0, 1], every cluster assignment is dominated by feature 3. The algorithm will partition along the axis of the largest-magnitude feature regardless of the actual cluster structure.

`StandardScaler` transforms each feature to zero-mean unit-variance, so all features contribute equally to the Euclidean distance.

**`PCA(n_components=10, random_state=42)`**

The dataset has 20 features. PCA decomposes the covariance matrix and returns the directions of maximum variance:

```python
pca = PCA(n_components=10, random_state=42)
X_reduced = pca.fit_transform(X_scaled)
print(np.cumsum(pca.explained_variance_ratio_))
# → [0.47 0.61 0.72 0.80 0.84 0.87 0.90 0.92 0.93 0.94]
# 10 components capture 94% of variance
```

The remaining 10 components (≈6% of variance) contain noise. By discarding them, we:
1. Reduce the dimensionality from 20 to 10 — distances are more meaningful in lower-dimensional space.
2. Remove noise dimensions that confuse the distance metric.

Result: ARI improves from ≈0.92 (no PCA) to ≈0.97 (with PCA).

**`KMeans(n_clusters=4, random_state=42, n_init=10)`**

- `n_clusters=4` — we know from the domain knowledge that there are 4 archetypes.
- `random_state=42` — fixes the initialisation for deterministic results.
- `n_init=10` — runs k-means 10 times with different random initialisations and keeps the best (lowest inertia). Default in sklearn ≥1.2 is also 10; setting it explicitly is defensive.

k-means can get stuck in local minima depending on the initial centroid placement. Running multiple initialisations and selecting the best is standard practice.

## What happens without PCA (still passes, but lower ARI)

```python
def cluster(X):
    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)
    km = KMeans(n_clusters=4, random_state=42, n_init=10)
    return km.fit_predict(X_scaled)
```

This achieves ARI ≈ 0.92 — still above the threshold of 0.85. PCA gives a higher score and is the recommended approach for real-world high-dimensional data, but is optional here.

## Elbow method — choosing k when you don't know it

In production you won't know there are 4 clusters. Use the elbow method:

```python
inertias = []
for k in range(2, 11):
    km = KMeans(n_clusters=k, random_state=42, n_init=10)
    km.fit(X_reduced)
    inertias.append(km.inertia_)

# Plot inertias vs k — the "elbow" (where the curve flattens) is the candidate k
```

Or silhouette analysis:

```python
from sklearn.metrics import silhouette_score

scores = []
for k in range(2, 11):
    km = KMeans(n_clusters=k, random_state=42, n_init=10)
    labels = km.fit_predict(X_reduced)
    scores.append(silhouette_score(X_reduced, labels))

best_k = range(2, 11)[np.argmax(scores)]
```

For this dataset both methods point to k=4.

## What the verifier actually checks

1. `cluster(X)` returns shape `(400,)`.
2. Labels are integers.
3. Between 2 and 8 unique label values.
4. `adjusted_rand_score(y_true, labels) >= 0.85`.
5. `silhouette_score(X, labels) >= 0.30` — sanity check that clusters are not degenerate.
6. ARI ≥ 0.85 on a second independent dataset (different `random_state`).

## Run it yourself

```bash
cd ~/.kube-dojo-work/06-cluster-and-reduce
. .venv/bin/activate
.venv/bin/pytest tests/ -v
bash courses/course-21-data-science-python/challenges/06-cluster-and-reduce/verify.sh
```
