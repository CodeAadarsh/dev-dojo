# Classify without Leakage

A colleague sends a PR for a new customer-churn classifier. The validation accuracy on their laptop is **97%**. You pull the branch and run their code — and immediately notice something is wrong. A senior review comment reads:

> *"This model will never ship. I count two data leakage bugs. Fix them, and if it still scores F1 ≥ 0.80 you have a real model. If it doesn't, the feature set needs revisiting — not patching the bugs back in."*

Your job: understand what leakage is, identify both bugs in the starter code, and implement a clean `build_pipeline()` that passes the verifier.

---

## What data leakage is — and why it destroys production models

Data leakage occurs when information that would not be available at prediction time (real production inference) is used during training or evaluation. The result: artificially inflated metrics during development, a model that appears excellent but fails in production.

```
Without leakage:

   Training data ──────▶ fit scaler ──▶ fit model ──────┐
                                                          │
   Test data ──────────▶ transform (training stats) ──▶ evaluate
                                                          │
   Production ──────────▶ transform (training stats) ──▶ predict
         ↑
   Consistent: test and production see the same transformation

With preprocessing leakage:

   ALL data ──────▶ fit scaler ──────┬──▶ training slice ──▶ fit model
                                     │
                                     └──▶ test slice ──▶ evaluate (inflated!)
         ↑
   The scaler "saw" the test rows during fit — test statistics
   leaked into the model's world-view
```

There are two distinct categories:

### 1. Feature leakage

A feature in the training set that directly encodes (or is derived from) the target variable. The model learns to rely on it. In production, this feature is not available for new examples — it had to be computed using the labels you don't have yet.

Classic example: including `target_encoded_mean` as a feature but computing it over the entire dataset before splitting. Or, in this challenge, a column constructed as `y + noise` — almost perfectly correlated with the target. A model that uses it will report near-perfect CV accuracy, but in production the column does not exist.

**Detection heuristic:** any feature with a correlation > 0.9 with the target *after* feature engineering is suspicious. Real-world features are noisy; a suspiciously clean signal is a red flag.

### 2. Preprocessing leakage (target leakage via transformation)

A scaler, imputer, or encoder is fit on the full dataset (train + test + validation) before the split. The parameters it computes (mean, std, category frequencies) are influenced by test-set rows. The model's training distribution is subtly shifted toward the test distribution.

This bug is insidious because:
- It does not crash.
- The effect is small on large, iid datasets (maybe a 0.5% optimistic boost).
- On small datasets or when the test set has distribution shift, the boost can be 5–10%.
- It makes cross-validation scores unreliable — you cannot trust your model selection.

**The fix is one line:** put the transformer inside a `Pipeline`, and call `pipe.fit(X_train, y_train)` — not `scaler.fit(X_all)` followed by `train_test_split`.

---

## The starter's two bugs

`setup.sh` plants `solution.py` with a `show_bad_example()` function that demonstrates the leaky pattern. Do not copy it — study it:

```python
# BUG 1: leaky feature — 'leaky' column is y + tiny noise
# This column does not exist for unseen customers in production.
X['leaky'] = y + rng.normal(0, 0.05, len(y))

# BUG 2: preprocessing leakage — scaler fit on ALL rows before split
scaler = StandardScaler()
X_scaled = scaler.fit_transform(X)   # test rows influence scaler params!

X_train, X_test, y_train, y_test = train_test_split(X_scaled, y, ...)
```

---

## How the verifier catches the leaky column

The hidden test evaluates your pipeline on `X_test_clean` — a version of the test set that has the `'leaky'` column **removed**. If your pipeline relies on `'leaky'`, it will raise a `ValueError` or `KeyError` when `pipeline.predict(X_test_clean)` is called. The F1 check will then also fail. Both checks collapse into a single pipeline that either works on clean data or does not.

```
Hidden test flow:
                                               drop 'leaky'
X_all ─────▶ add 'leaky' column ─────▶ split ──────────────▶ X_test_clean
                                          │
                                          └──▶ X_train (has 'leaky')
                                                    │
                                                    ▼
                                         build_pipeline(X_train, y_train)
                                                    │
                                         pipeline.predict(X_test_clean)
                                                    │
                                         f1_score(...) >= 0.80 ?
```

Your `build_pipeline` receives `X_train` as a DataFrame that includes `'leaky'`. It must drop that column internally (inside the Pipeline, or before constructing it) so that `predict(X_test_clean)` — which has no `'leaky'` column — still works.

---

## The dataset

```python
from sklearn.datasets import make_classification
import numpy as np, pandas as pd

X_raw, y = make_classification(
    n_samples=600, n_features=15, n_informative=10,
    n_redundant=2, random_state=42
)
X = pd.DataFrame(X_raw, columns=[f'f{i}' for i in range(15)])
X['leaky'] = y + np.random.default_rng(99).normal(0, 0.05, len(y))

X_train, X_test_clean, y_train, y_test = train_test_split(
    X.drop(columns=['leaky']),   # test set never had it
    y, test_size=0.2, random_state=42
)
X_train_full = pd.concat([X_train, ...])  # hidden test reconstructs X_train with leaky
```

The base dataset has 15 real features, 10 informative. A logistic regression or random forest on the 15-feature set (no leaky column, preprocessing inside Pipeline) should achieve weighted F1 ≈ 0.86–0.92. The threshold is **F1 ≥ 0.80**.

---

## Implementing a leak-free pipeline with pandas DataFrames

When your input is a DataFrame, use `ColumnTransformer` to select which columns to scale — and explicitly exclude `'leaky'`:

```python
from sklearn.pipeline import Pipeline
from sklearn.compose import ColumnTransformer
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import LogisticRegression

def build_pipeline(X_train, y_train):
    # Feature columns — everything except the leaky column
    feature_cols = [c for c in X_train.columns if c != 'leaky']

    preprocessor = ColumnTransformer([
        ('scale', StandardScaler(), feature_cols),
    ])

    pipe = Pipeline([
        ('prep',  preprocessor),
        ('model', LogisticRegression(max_iter=1000, random_state=42)),
    ])
    pipe.fit(X_train, y_train)
    return pipe
```

`ColumnTransformer` tells sklearn which columns to use. By omitting `'leaky'`, even if it is present in X_train, it is never seen by the model. When `predict(X_test_clean)` is called (no `'leaky'` column at all), the ColumnTransformer looks for `feature_cols` only — the column that's not there was never referenced, so no error is raised.

---

## Prerequisites

```bash
cd ~/.kube-dojo-work/05-classify-without-leakage
python3 -m venv .venv && . .venv/bin/activate
pip install pytest numpy pandas scikit-learn
```

## Work directory

`setup.sh` plants:

```
~/.kube-dojo-work/05-classify-without-leakage/
├── solution.py          # study show_bad_example(), implement build_pipeline()
└── tests/
    └── test_sample.py   # two visible tests you can run locally
```

## Mission

Implement `build_pipeline(X_train, y_train)` in `solution.py`:

- **Input:** `X_train` — a pandas DataFrame with columns `['f0'…'f14', 'leaky']` (16 columns); `y_train` — a 1-D NumPy array.
- **Output:** a **fitted** `sklearn.pipeline.Pipeline` that:
  1. Does **not** use the `'leaky'` column.
  2. Applies preprocessing **inside** the pipeline (not before split).
  3. Achieves weighted **F1 ≥ 0.80** when evaluated on the clean test set (no `'leaky'` column).

## Verify

```bash
bash courses/course-21-data-science-python/challenges/05-classify-without-leakage/verify.sh
```

F1 ≥ 0.80 on `X_test_clean` (no leaky column) AND no predict error → flag printed.
