# Unsupervised Learning & a Capstone

> **Module 07 · Course 21** — Unsupervised learning is what you reach for when there are no labels — or when you want to understand the structure of your data before modeling it. This module covers clustering, dimensionality reduction, and feature engineering, then ties the entire course together in a worked capstone you can run end-to-end.

The capstone follows exactly the pipeline a working data scientist uses: raw data in, a trained, evaluated model out. Every step is explicit, every decision is justified.

---

## Clustering

Clustering finds structure in unlabeled data by grouping similar points together. The algorithms agree on the goal but disagree on how "similar" is defined and what "a group" means.

```
Unlabeled data                  After clustering (k=3)
   ·  ··                            ●  ●●
 ·  ·   ·                         ●  ●   ●
       ·    ·                           ▲    ▲
  ·  ·        ·          →       ▲  ▲        ▲
         ·  ·                         ■  ■
   ·  ·                          ■  ■
No information about groups      Three clusters identified
```

### k-Means

k-Means partitions `n` points into `k` clusters by minimizing the sum of squared distances from each point to its cluster centroid.

```python
from sklearn.cluster import KMeans
import numpy as np

# Always scale before k-means — distance is in feature space
from sklearn.preprocessing import StandardScaler
X_scaled = StandardScaler().fit_transform(X)

km = KMeans(
    n_clusters=3,
    n_init=10,        # run with 10 different random centroid seeds; keep best
    random_state=42,
    max_iter=300,
)
km.fit(X_scaled)

labels = km.labels_              # cluster assignment per point
centers = km.cluster_centers_    # centroid coordinates in scaled space
inertia = km.inertia_            # sum of squared distances to centroids (lower = tighter)
```

**How k-Means works internally (Lloyd's algorithm):**

```
1. Initialize: place k centroids at random points (or k-means++ heuristic)
2. Assign: each point gets the label of its nearest centroid
3. Update: move each centroid to the mean of its assigned points
4. Repeat 2-3 until assignments stop changing (or max_iter reached)
```

The `k-means++` initialization (sklearn's default since ~1.0) spreads initial centroids far apart, reducing the chance of a bad local minimum.

### The Elbow Method: Choosing k

```python
inertias = []
K_range = range(2, 11)

for k in K_range:
    km = KMeans(n_clusters=k, n_init=10, random_state=42)
    km.fit(X_scaled)
    inertias.append(km.inertia_)

# Plot inertia vs k; look for the "elbow" where the curve bends
# The elbow is the k where adding another cluster gives diminishing returns
import matplotlib.pyplot as plt
plt.plot(K_range, inertias, 'bx-')
plt.xlabel('k')
plt.ylabel('Inertia')
plt.title('Elbow Method')
plt.show()
```

The elbow method is a heuristic, not a formula. In practice, use the silhouette score alongside it.

### Silhouette Score

The silhouette score measures how similar a point is to its own cluster versus the nearest other cluster. It ranges from -1 (wrong cluster) to +1 (well-separated cluster).

```python
from sklearn.metrics import silhouette_score

silhouette_scores = []
for k in range(2, 11):
    km = KMeans(n_clusters=k, n_init=10, random_state=42)
    labels = km.fit_predict(X_scaled)
    score = silhouette_score(X_scaled, labels)
    silhouette_scores.append(score)

best_k = K_range[np.argmax(silhouette_scores)]
print(f"Best k by silhouette: {best_k}, score: {max(silhouette_scores):.3f}")
# Silhouette > 0.5 → reasonable structure; > 0.7 → strong structure
```

Per-sample silhouette shows which points are in ambiguous boundary zones:

```python
from sklearn.metrics import silhouette_samples
sample_silhouette = silhouette_samples(X_scaled, km.labels_)
# Points near 0 are on cluster boundaries; negative points are likely misclustered
```

### k-Means Limitations

```
k-Means assumes:
1. Clusters are spherical (isotropic) — it fails on elongated or non-convex shapes
2. Clusters have similar size — large clusters get fragmented
3. Clusters have similar density — sparse clusters get absorbed

Example failure:
       ·  ·  ·        ·  ·  ·
  ·  ·   ·              ·    ·
                           ·  ·
  (concentric rings)   (irregular shapes)
  k-Means fails          DBSCAN handles
```

### DBSCAN

DBSCAN (Density-Based Spatial Clustering of Applications with Noise) finds clusters as dense regions separated by sparse regions. It does not require specifying `k` upfront and handles arbitrary shapes.

```python
from sklearn.cluster import DBSCAN

db = DBSCAN(
    eps=0.5,          # maximum distance between two points to be considered neighbors
    min_samples=5,    # minimum points to form a core point (dense region)
)
labels = db.fit_predict(X_scaled)

# Labels: 0, 1, 2, ... are cluster IDs
# Label -1 = noise (does not belong to any cluster)
n_clusters = len(set(labels)) - (1 if -1 in labels else 0)
n_noise = list(labels).count(-1)
print(f"Clusters: {n_clusters}, Noise points: {n_noise}")
```

DBSCAN hyperparameters:

| Parameter | Effect | Choosing it |
|-----------|--------|-------------|
| `eps` | Neighborhood radius | Use a k-distance plot: sort distances to k-th nearest neighbor; look for the knee |
| `min_samples` | Minimum density to form a cluster | Rule of thumb: `2 * n_features` for low-dimensional data |

```python
# k-distance plot for choosing eps
from sklearn.neighbors import NearestNeighbors
nn = NearestNeighbors(n_neighbors=5)   # min_samples=5
nn.fit(X_scaled)
distances, _ = nn.kneighbors(X_scaled)
distances = np.sort(distances[:, -1])   # distance to 5th nearest neighbor
plt.plot(distances)
plt.ylabel('5th-NN distance')
plt.title('k-Distance Plot — look for the knee')
plt.show()
# eps = the distance value at the knee of this curve
```

---

## Dimensionality Reduction: PCA

Principal Component Analysis finds the directions of maximum variance in your data and projects onto them. It is used for visualization (project to 2D), noise reduction, and as a preprocessing step to reduce feature count before modeling.

```
Original 3D data           After PCA → 2D
     z ↑                   PC2 ↑
       │  · ·                  │    ·
       │·   ·    →             │  ·   ·
       │      ·                │         ·
       └──────→ x              └──────────→ PC1
         → y                  (most variance is captured in 2 dimensions)
```

```python
from sklearn.decomposition import PCA

# Always scale before PCA — unscaled features with large variance dominate
X_scaled = StandardScaler().fit_transform(X)

# Fit with all components to inspect explained variance
pca = PCA(n_components=None, random_state=42)
pca.fit(X_scaled)

print(pca.explained_variance_ratio_)
# [0.45, 0.21, 0.14, 0.08, 0.05, ...]
# First component explains 45% of variance, second 21%, ...

cumvar = pca.explained_variance_ratio_.cumsum()
# Find n_components to explain 95% of variance:
n_95 = np.argmax(cumvar >= 0.95) + 1
print(f"Components needed for 95% variance: {n_95}")
```

```python
# Scree plot — variance explained per component
plt.plot(range(1, len(pca.explained_variance_ratio_) + 1),
         pca.explained_variance_ratio_, 'o-')
plt.xlabel('Principal Component')
plt.ylabel('Explained Variance Ratio')
plt.axvline(x=n_95, linestyle='--', color='red', label=f'n={n_95} (95%)')
plt.legend()
plt.show()
```

```python
# Apply PCA with chosen n_components
pca_final = PCA(n_components=n_95, random_state=42)
X_pca = pca_final.fit_transform(X_scaled)

# For visualization (2D):
pca_2d = PCA(n_components=2, random_state=42)
X_2d = pca_2d.fit_transform(X_scaled)
plt.scatter(X_2d[:, 0], X_2d[:, 1], c=labels, cmap='tab10', alpha=0.6)
plt.xlabel('PC1')
plt.ylabel('PC2')
plt.title('PCA Projection (2D)')
plt.show()
```

PCA inside a Pipeline (the correct pattern):

```python
from sklearn.pipeline import Pipeline
from sklearn.ensemble import RandomForestClassifier

pipe = Pipeline([
    ('scaler', StandardScaler()),
    ('pca',    PCA(n_components=0.95, random_state=42)),  # 0.95 means keep 95% of variance
    ('model',  RandomForestClassifier(n_estimators=200, random_state=42)),
])
pipe.fit(X_train, y_train)
```

---

## Feature Engineering

Feature engineering is the practice of constructing new features from existing ones to make patterns more accessible to the model. This is where domain knowledge compounds — a well-engineered feature can outperform a more complex model on raw data.

```python
import pandas as pd
import numpy as np

df = pd.read_csv('employees.csv')

# ── Numeric transformations ────────────────────────────────────────────────────
# Log transform skewed features (salary, counts, durations)
df['log_salary'] = np.log1p(df['salary'])    # log1p = log(1+x), handles 0
df['log_tenure'] = np.log1p(df['tenure_days'])

# Binning a continuous variable into categories
df['age_band'] = pd.cut(df['age'], bins=[18, 25, 35, 45, 60, 100],
                        labels=['18-25', '26-35', '36-45', '46-60', '60+'])

# ── Interaction features ───────────────────────────────────────────────────────
# Polynomial interactions capture nonlinear relationships
from sklearn.preprocessing import PolynomialFeatures
poly = PolynomialFeatures(degree=2, interaction_only=True, include_bias=False)
X_poly = poly.fit_transform(X_numeric)
# This can explode feature count: n features → n*(n-1)/2 pairwise interactions

# Manual domain interactions are better than blind polynomial expansion
df['salary_per_year'] = df['salary'] / df['tenure_years'].clip(lower=1)
df['projects_per_month'] = df['n_projects'] / df['tenure_months'].clip(lower=1)

# ── Datetime features ──────────────────────────────────────────────────────────
df['hire_date'] = pd.to_datetime(df['hire_date'])
df['hire_month'] = df['hire_date'].dt.month
df['hire_quarter'] = df['hire_date'].dt.quarter
df['hire_dayofweek'] = df['hire_date'].dt.dayofweek
df['tenure_days'] = (pd.Timestamp.now() - df['hire_date']).dt.days

# ── Aggregation features (group statistics) ────────────────────────────────────
# Per-department stats — compute on training data only!
dept_stats = df_train.groupby('department')['salary'].agg(['mean', 'std', 'count'])
dept_stats.columns = ['dept_salary_mean', 'dept_salary_std', 'dept_headcount']
df = df.merge(dept_stats, on='department', how='left')
```

---

## Capstone: Employee Churn Prediction End-to-End

This capstone uses a synthetic HR dataset. The goal: predict which employees will churn (leave) within the next 3 months. We follow the full workflow from raw data to a final, interpreted model.

### Step 1: Load and Inspect

```python
import pandas as pd
import numpy as np
from sklearn.model_selection import train_test_split, StratifiedKFold, cross_validate
from sklearn.pipeline import Pipeline
from sklearn.compose import ColumnTransformer
from sklearn.preprocessing import StandardScaler, OneHotEncoder
from sklearn.impute import SimpleImputer
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import (
    classification_report, roc_auc_score,
    ConfusionMatrixDisplay, average_precision_score,
)
import matplotlib.pyplot as plt

df = pd.read_csv('hr_data.csv')

print(df.shape)         # (8000, 14)
print(df.dtypes)
print(df.isnull().sum())    # check missingness per column
print(df['churned'].value_counts(normalize=True))
# 0    0.847
# 1    0.153  ← imbalanced: ~15% churn rate
```

### Step 2: Clean

```python
# Drop columns with > 50% missing — they hurt more than they help
missing_rate = df.isnull().mean()
df = df.drop(columns=missing_rate[missing_rate > 0.5].index)

# Remove duplicates
df = df.drop_duplicates()

# Cap extreme outliers in numeric columns at the 99th percentile
for col in ['salary', 'overtime_hours', 'tenure_days']:
    cap = df[col].quantile(0.99)
    df[col] = df[col].clip(upper=cap)

# Drop rows where the target is missing
df = df.dropna(subset=['churned'])
```

### Step 3: EDA

```python
# Churn rate by department
churn_by_dept = df.groupby('department')['churned'].mean().sort_values(ascending=False)
print(churn_by_dept)
# Engineering  0.23
# Sales        0.19
# Finance      0.11  ← finance retains best

# Churn rate by salary quartile
df['salary_q'] = pd.qcut(df['salary'], q=4, labels=['Q1', 'Q2', 'Q3', 'Q4'])
print(df.groupby('salary_q')['churned'].mean())
# Q1 (lowest)  0.28 ← lowest salary → highest churn

# Correlation between numeric features and churn
print(df.select_dtypes(include='number').corr()['churned'].sort_values())
# tenure_days     -0.34  ← longer tenure = less churn
# salary          -0.27
# overtime_hours   0.22  ← overtime = burnout = churn
```

### Step 4: Feature Engineering

```python
# Log-transform skewed features
df['log_salary'] = np.log1p(df['salary'])
df['log_tenure'] = np.log1p(df['tenure_days'])

# Overtime rate (weekly hours above baseline)
df['overtime_rate'] = df['overtime_hours'] / df['tenure_months'].clip(lower=1)

# Salary relative to department average
dept_salary_mean = df.groupby('department')['salary'].transform('mean')
df['salary_vs_dept'] = df['salary'] / dept_salary_mean

# Target and features
feature_cols = [
    'log_salary', 'log_tenure', 'overtime_rate', 'salary_vs_dept',
    'age', 'n_projects', 'last_review_score',
    'department', 'role_level', 'work_type',
]
X = df[feature_cols]
y = df['churned']
```

### Step 5: Split

```python
X_train, X_test, y_train, y_test = train_test_split(
    X, y,
    test_size=0.2,
    random_state=42,
    stratify=y,    # preserves 15% churn rate in both splits
)
print(y_train.value_counts(normalize=True))
print(y_test.value_counts(normalize=True))
# Both should show ~0.85/0.15 split
```

### Step 6: Pipeline

```python
numeric_features = ['log_salary', 'log_tenure', 'overtime_rate', 'salary_vs_dept',
                    'age', 'n_projects', 'last_review_score']
categorical_features = ['department', 'role_level', 'work_type']

numeric_pipe = Pipeline([
    ('imputer', SimpleImputer(strategy='median')),
    ('scaler',  StandardScaler()),
])

categorical_pipe = Pipeline([
    ('imputer', SimpleImputer(strategy='most_frequent')),
    ('encoder', OneHotEncoder(sparse_output=False, handle_unknown='ignore')),
])

preprocessor = ColumnTransformer([
    ('num', numeric_pipe,  numeric_features),
    ('cat', categorical_pipe, categorical_features),
])

pipeline = Pipeline([
    ('preprocessor', preprocessor),
    ('model', HistGradientBoostingClassifier(
        max_iter=300,
        max_depth=5,
        learning_rate=0.05,
        random_state=42,
    )),
])
```

### Step 7: Cross-Validate

```python
cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)

results = cross_validate(
    pipeline, X_train, y_train,
    cv=cv,
    scoring=['roc_auc', 'average_precision', 'f1'],
    return_train_score=True,
    n_jobs=-1,
)

df_cv = pd.DataFrame(results)
print(df_cv[['train_roc_auc', 'test_roc_auc',
             'train_f1', 'test_f1']].agg(['mean', 'std']).round(3))

# Expected output (roughly):
#        train_roc_auc  test_roc_auc  train_f1  test_f1
# mean           0.963         0.891     0.824    0.701
# std            0.004         0.012     0.011    0.019
#
# Gap ~7% on AUC — acceptable generalization, some overfit
# If train F1 were 0.99 and test F1 were 0.40 → severe overfit → reduce max_depth
```

### Step 8: Final Evaluation on Test Set

```python
# Fit on all training data
pipeline.fit(X_train, y_train)

# Predict
y_pred = pipeline.predict(X_test)
y_proba = pipeline.predict_proba(X_test)[:, 1]

# Metrics
print(f"ROC-AUC:  {roc_auc_score(y_test, y_proba):.3f}")
print(f"Avg Prec: {average_precision_score(y_test, y_proba):.3f}")
print()
print(classification_report(y_test, y_pred, target_names=['stayed', 'churned']))
```

### Step 9: Threshold Tuning

The default threshold 0.5 is rarely optimal for imbalanced data. Tune it for the business objective:

```python
from sklearn.metrics import precision_recall_curve

precision, recall, thresholds = precision_recall_curve(y_test, y_proba)

# Business objective: catch 70% of churners (recall >= 0.70)
# Find the highest threshold that achieves this
valid_idx = np.where(recall >= 0.70)[0]
if len(valid_idx) > 0:
    best_idx = valid_idx[np.argmax(precision[valid_idx])]
    best_threshold = thresholds[best_idx]
    print(f"Threshold {best_threshold:.3f}: "
          f"Precision={precision[best_idx]:.3f}, Recall={recall[best_idx]:.3f}")

# Apply the tuned threshold
y_pred_tuned = (y_proba >= best_threshold).astype(int)
print(classification_report(y_test, y_pred_tuned, target_names=['stayed', 'churned']))
```

### Step 10: Interpret

```python
from sklearn.inspection import permutation_importance

# Permutation importance on test set — model-agnostic
result = permutation_importance(
    pipeline, X_test, y_test,
    n_repeats=10,
    random_state=42,
    scoring='roc_auc',
    n_jobs=-1,
)

feat_imp = pd.Series(
    result.importances_mean,
    index=feature_cols,
).sort_values(ascending=False)

print(feat_imp.head(10))
# log_tenure         0.041  ← most important
# last_review_score  0.031
# salary_vs_dept     0.028
# overtime_rate      0.023
# log_salary         0.019
# ...
```

The interpretation: tenure, review score, and whether someone is paid below their department average are the top drivers of churn — which makes business sense and adds confidence that the model is not using a leaky feature.

---

## Debugging Unsupervised Learning

### Bug 1: Choosing k by eyeballing inertia alone

```python
# Inertia always decreases as k increases — it never tells you to stop
# Using only the elbow method you might pick k=4 when k=3 is correct

# Fix: use silhouette score to validate
for k in range(2, 8):
    km = KMeans(n_clusters=k, n_init=10, random_state=42)
    labels = km.fit_predict(X_scaled)
    sil = silhouette_score(X_scaled, labels)
    print(f"k={k}: inertia={km.inertia_:.1f}, silhouette={sil:.3f}")
# Pick k where silhouette is highest and the elbow is near
```

### Bug 2: Clustering on unscaled features

```python
# WRONG: a salary column in [0, 200000] dominates a tenure column in [0, 10]
km = KMeans(n_clusters=3, n_init=10, random_state=42)
labels = km.fit_predict(X_raw)   # salary dominates entirely
# Result: clusters are just high/medium/low salary groups regardless of other features

# CORRECT: always scale before any distance-based algorithm
from sklearn.preprocessing import StandardScaler
X_scaled = StandardScaler().fit_transform(X_raw)
labels = km.fit_predict(X_scaled)

# Check you're not inadvertently running on unscaled data:
print(X_raw.std(axis=0))     # should show very different scales
print(X_scaled.std(axis=0))  # should all be ~1.0
```

### Bug 3: PCA on unscaled data

```python
# WRONG: PCA on raw features
pca = PCA(n_components=2)
X_pca = pca.fit_transform(X_raw)
# First principal component ≈ salary direction (highest variance = largest scale)
# All other structure is suppressed

# CORRECT: scale first
X_scaled = StandardScaler().fit_transform(X_raw)
pca = PCA(n_components=2)
X_pca = pca.fit_transform(X_scaled)

# Verify: check explained variance
print(pca.explained_variance_ratio_)
# If first component explains > 95%: you likely forgot to scale
# Healthy: [0.32, 0.21, 0.15, ...] — variance spread across components
```

### Bug 4: DBSCAN all points flagged as noise

```python
# Symptom: all labels == -1, n_clusters == 0
# Cause: eps is too small — no point has min_samples neighbors within eps

# Diagnosis: check the k-distance plot
nn = NearestNeighbors(n_neighbors=5)
nn.fit(X_scaled)
dists, _ = nn.kneighbors(X_scaled)
dists_sorted = np.sort(dists[:, -1])
print(f"5th-NN distances: min={dists_sorted.min():.3f}, "
      f"median={np.median(dists_sorted):.3f}, max={dists_sorted.max():.3f}")
# Set eps to a value near the knee of the distance curve
# A value of median * 0.8 is a reasonable starting point
```

---

## Checkpoint

1. k-Means minimizes what quantity? What does a high inertia with a high silhouette score indicate?
2. You run k-Means and get very different cluster assignments on two different random seeds. What does this tell you about your data?
3. DBSCAN returns 80% noise points. What two hyperparameters do you adjust, and in which direction?
4. You apply PCA and the first component alone explains 92% of variance on raw (unscaled) data. What's almost certainly wrong?
5. Name two feature engineering techniques specifically designed to handle skewed numeric distributions.
6. In the capstone, why is the `salary_vs_dept` feature computed from a training-only `groupby` rather than the full dataset?
7. You reach the interpret step and see `user_id` in the top-3 permutation importances. What does this tell you about the dataset or your pipeline?
8. Your pipeline's cross-validated ROC-AUC is 0.89, but when you lower the threshold to 0.3 on the test set and recheck, you report the new F1. A colleague says this is fine since you're not retraining. Are they right?

---

## What's Next

You have now completed the core data science track:

| Module | Topic | Key skill |
|--------|-------|-----------|
| 01 | NumPy vectorization | No loops — operate on arrays |
| 02 | pandas wrangling | groupby, merge, reshape |
| 03 | EDA & visualization | matplotlib, seaborn, describe |
| 04 | Statistics & probability | distributions, hypothesis tests |
| 05 | scikit-learn workflow | Estimator API, Pipeline, ColumnTransformer |
| 06 | Model evaluation | metrics, cross-val, leakage, bias-variance |
| 07 | Unsupervised + capstone | clustering, PCA, end-to-end |

The challenges in this course are where the theory meets a graded verifier. Each challenge plants a skeleton in your work directory, runs a hidden pytest suite, and produces a flag only when all tests pass. The same pipeline you built in this module is the tool you'll use — the challenge is to implement it correctly under constraints.

Start with the data cleaning challenge and work forward. The capstone challenge is the final boss: a raw CSV, a problem statement, and a single target metric you must beat.
