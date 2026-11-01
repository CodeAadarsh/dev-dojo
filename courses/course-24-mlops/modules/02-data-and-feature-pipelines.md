# Data & Feature Pipelines

> **Module 02 · Course 24** — "Our features are ready" is the sentence before the most expensive debugging sessions in ML. A feature that looks right in training silently lies in serving. This module is about building pipelines whose correctness you can assert, not just eyeball.

---

## Pipeline stages: the anatomy of a data path

A data pipeline for ML has four distinct responsibilities. Conflating them is the primary source of leakage and skew bugs.

```
Raw storage                     Feature store
(S3, GCS, DB, Kafka)            (Feast, Tecton, Hopsworks, Redis)
        │                                │
        │ 1. Ingest & validate           │  4. Serve to model
        ▼                                ▼
  Raw feature table            ┌─────────────────────────────────┐
        │                      │  Online store                   │
        │ 2. Transform          │  (low-latency, real-time)       │
        ▼                      │  feature lookup by entity key   │
  Computed features            └─────────────────────────────────┘
        │                                │
        │ 3. Materialise                  │
        ▼                                ▼
  ┌─────────────────────┐       Training dataset
  │  Offline store      │──────► (point-in-time correct join)
  │  (Parquet, BigQuery) │
  └─────────────────────┘
```

**Stage 1 — Ingest & validate:** schema check, null checks, range checks, record count sanity. Fail loudly here or pay silently later.

**Stage 2 — Transform:** feature engineering as code (see below). This stage must be bit-identical between training and serving.

**Stage 3 — Materialise:** write computed features to the offline store (batch history) and online store (latest snapshot per entity). The materialisation job is what keeps them in sync.

**Stage 4 — Serve:** at inference time, the serving system queries the online store by entity key (user ID, item ID) and assembles the feature vector that the model expects.

---

## Feature engineering as code

Feature engineering must be:
- **Deterministic** — same input, same output, always.
- **Versioned** — the exact `transform.py` that produced the training data must be what runs at serve time.
- **Independent of the train/val/test split** — transforms that use global statistics (`StandardScaler`, `TargetEncoder`) must be fitted on `X_train` only, then applied to all sets.

```python
# transforms.py — a canonical feature engineering module
import numpy as np
import pandas as pd
from sklearn.base import BaseEstimator, TransformerMixin

class LogTransform(BaseEstimator, TransformerMixin):
    """log1p transform for right-skewed continuous features."""
    def __init__(self, columns):
        self.columns = columns

    def fit(self, X, y=None):
        return self  # stateless; no leakage possible

    def transform(self, X):
        X = X.copy()
        for col in self.columns:
            X[col] = np.log1p(X[col].clip(lower=0))
        return X


class FrequencyEncoder(BaseEstimator, TransformerMixin):
    """Replace a categorical with its training-set frequency."""
    def __init__(self, column):
        self.column = column
        self.freq_map_ = {}

    def fit(self, X, y=None):
        # fit on X_train ONLY — this is state; serve with the fitted object
        counts = X[self.column].value_counts(normalize=True)
        self.freq_map_ = counts.to_dict()
        return self

    def transform(self, X):
        X = X.copy()
        X[self.column] = X[self.column].map(self.freq_map_).fillna(0.0)
        return X
```

Because both transformers implement the scikit-learn `fit`/`transform` interface, they compose cleanly with `sklearn.pipeline.Pipeline` and serialize together with the model:

```python
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.ensemble import GradientBoostingClassifier

pipeline = Pipeline([
    ("log",   LogTransform(columns=["amount", "days_since_last_tx"])),
    ("freq",  FrequencyEncoder(column="merchant_category")),
    ("scale", StandardScaler()),
    ("clf",   GradientBoostingClassifier(n_estimators=200, random_state=42)),
])

pipeline.fit(X_train, y_train)     # StandardScaler sees only X_train
pipeline.predict_proba(X_test)     # uses the fitted scaler — no leakage

import joblib; joblib.dump(pipeline, "model/pipeline.pkl")
# The serialised blob contains the scaler's mean_/var_, the freq_map_, and the model.
```

Deploying the pipeline blob is the single most important thing you can do to prevent train/serve skew. The alternative — fitting the scaler separately, saving it separately, loading it separately in two places — guarantees they will eventually diverge.

---

## Feature stores: online vs offline

| Dimension | Offline store | Online store |
|-----------|--------------|-------------|
| Storage format | Parquet / Delta / BigQuery | Redis, DynamoDB, Cassandra |
| Access pattern | batch scan (training) | point lookup by entity key (serving) |
| Latency | seconds–minutes | < 5 ms |
| Freshness | hourly or daily materialisation job | materialised per event or per micro-batch |
| Row semantics | historical record with `event_timestamp` | latest snapshot per `entity_id` |

The critical invariant: **the feature vector seen during serving must be computable from the same logic that produced the training dataset.** If you add a feature to the online store but forget to backfill it into the offline store, training data will be missing that column and you'll get a shape mismatch error at best, and a `NaN`-imputed silent degradation at worst.

### Point-in-time correct joins

The hardest correctness problem in offline feature stores is the point-in-time join. Naively joining a training label table to feature tables by entity ID leaks future information:

```
label table:
  user_id=123, label=churned, event_ts=2024-03-15

feature table (wrong naive join):
  user_id=123, lifetime_value=450  ← as of today (March 20)
  ← the model saw the LTV AFTER the churn event; this is future leakage
```

A point-in-time join uses `event_ts` from the label as the lookup cutoff:

```python
# Feast SDK point-in-time retrieval
from feast import FeatureStore
store = FeatureStore(repo_path=".")

training_df = store.get_historical_features(
    entity_df=labels_df,       # must have entity key + event_timestamp column
    features=["user_stats:lifetime_value", "user_stats:tx_count_30d"],
).to_df()
# Feast returns the feature value AS OF each row's event_timestamp — no future leakage
```

Without a feature store enforcing this, the point-in-time join must be implemented manually — and it is wrong more often than it is right.

---

## Data validation: schema and distribution

### Schema validation

Use `pandera` or `great_expectations` for schema contracts. A minimal `pandera` schema:

```python
import pandera as pa
from pandera import Column, DataFrameSchema, Check

schema = DataFrameSchema({
    "user_id":      Column(int,   nullable=False),
    "amount":       Column(float, Check.greater_than_or_equal_to(0.0)),
    "merchant_cat": Column(str,   Check.isin(["food", "travel", "retail", "other"])),
    "event_ts":     Column("datetime64[ns]"),
})

validated = schema.validate(raw_df)   # raises SchemaError on violation
```

Run schema validation at **both ends** of the pipeline: on ingestion (catch upstream data changes early) and on the assembled training dataset (catch transform bugs).

### Distribution validation

Schema says "this column is a float." Distribution validation says "this float is behaving like it did last month." The two standard measures:

**Population Stability Index (PSI):** monitors how much a feature's distribution has shifted between a reference window (training) and a current window (serving or new batch).

```
PSI = Σ (actual_pct - expected_pct) × ln(actual_pct / expected_pct)

PSI < 0.1  → stable, no action
0.1 ≤ PSI < 0.2 → moderate shift, investigate
PSI ≥ 0.2  → significant shift, retrain likely needed
```

**Kolmogorov-Smirnov test (KS):** non-parametric test for distribution equality. Useful for continuous features.

```python
from scipy import stats

ks_stat, p_value = stats.ks_2samp(train_values, serving_values)
if p_value < 0.05:
    print(f"Feature '{col}' distribution has shifted (KS p={p_value:.4f})")
```

Track both at the feature level for every daily or hourly batch. The first feature that drifts is almost always upstream of the bug.

---

## Leakage prevention: the checklist

Leakage is when information from the future (or from the target) contaminates the training data, producing optimistic metrics that do not generalise.

| Leakage type | Example | Prevention |
|-------------|---------|-----------|
| **Target leakage** | Using `fraud_review_flag` (set after fraud is confirmed) as a feature | Audit every feature against the target definition: can this value be known at prediction time? |
| **Temporal leakage** | Joining features without a point-in-time cutoff | Use a feature store with PIT joins; always join on `event_ts ≤ label_ts` |
| **Split leakage** | Fitting the scaler on the full dataset before the train/test split | Fit all stateful transforms inside a `Pipeline`, `fit` on train only |
| **Group leakage** | Shuffling randomly when groups (users, sessions) should not straddle splits | Use `GroupShuffleSplit` or time-based splits |

```python
# Wrong — scaler sees val and test:
scaler = StandardScaler()
X_all_scaled = scaler.fit_transform(X)
X_train, X_test = train_test_split(X_all_scaled, random_state=42)

# Right — scaler sees only train:
X_train, X_test = train_test_split(X, random_state=42)
scaler = StandardScaler()
X_train_scaled = scaler.fit_transform(X_train)
X_test_scaled  = scaler.transform(X_test)       # transform, NOT fit_transform
```

**Time-based splits** are mandatory for any time-series or sequential model. Random shuffle with temporal data leaks future into train:

```python
# Time-based split — no leakage for sequential data
cutoff = df["event_ts"].quantile(0.8)
train = df[df["event_ts"] <= cutoff]
test  = df[df["event_ts"] >  cutoff]
```

---

## Debugging Data & Feature Pipelines

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Model AUC drops sharply after rollout | Train/serve skew — the transform in prod uses different statistics than training | Compare the scaler's `mean_` / `scale_` stored at train time vs what prod is using; serialize the full sklearn Pipeline together |
| Feature is present in training but `KeyError` at serve time | New feature added to model but not materialised to the online store | Add the feature to the online store materialisation job and re-materialise before deploying the new model |
| Offline model eval shows AUC 0.95; shadow-mode shadow eval shows 0.72 | Feature leakage in offline eval (future data visible) | Audit all joins for PIT correctness; check for target-leakage features |
| Validation loss diverges after epoch 3 when it didn't before | A stateful transform (encoder) was re-fitted on val fold in CV | Move all transforms inside a `Pipeline`; scikit-learn CV re-fits them per fold correctly |
| Distribution alert fires on feature `X` but model seems fine | Upstream schema change (e.g., null proportion doubled) that the model is robust to, or stale alert threshold | Investigate root cause upstream; update PSI threshold based on current known-good distribution |
| Stale features in the online store (values from hours ago) | Materialisation job failed silently | Add monitoring to the materialisation job with a max-age assertion; alert if last materialisation > SLA |

> **War story.** A churn model was being retrained monthly with a reported AUC of 0.88. After three months, a product manager noticed that "high churn risk" scores were not correlating with actual churn. Investigating, we found that `support_tickets_last_30d` — the most important feature — was being joined from a snapshot table that was refreshed weekly, not at the point in time of the label. For labels dated any day other than the snapshot day, the ticket count was from the future relative to the label. Offline AUC was inflated by roughly 0.09. The fix was a proper PIT join via a Feast historical retrieval. The "real" AUC was 0.79 — still useful, but the team had been planning business interventions on a number that was 9 points optimistic. The data validation suite caught the distribution mismatch; the root cause required reading the materialisation schedule.

---

## Checkpoint

You are ready for the challenges in this course when you can, without looking anything up:

1. Draw the four pipeline stages (ingest → transform → materialise → serve) and name where each of: train/serve skew, temporal leakage, and stale features can originate.
2. Implement a stateful sklearn-compatible transformer that encodes a categorical with training-set frequency, and explain why `fit` must not be called on val/test data.
3. Describe the difference between an offline store and an online store in terms of access pattern, latency, and the materialisation job that bridges them.
4. Explain what a point-in-time correct join is and write the pandas condition that enforces it manually (no feature store SDK).
5. Compute PSI by hand for a two-bucket example and state the threshold above which you would trigger a retrain investigation.
6. Identify the two lines in this snippet that cause leakage: `scaler.fit_transform(X)` before `train_test_split` and a join without a `≤ label_ts` cutoff.
7. Write a `pandera` schema that validates three columns with types, a non-null constraint, and a range check, and explain where in the pipeline to call `schema.validate()`.
8. Name three leakage types, give one concrete example of each, and state the prevention for each.

➡ Next up: **Experiment Tracking & the Model Registry** — making every run addressable, comparable, and promotable.
