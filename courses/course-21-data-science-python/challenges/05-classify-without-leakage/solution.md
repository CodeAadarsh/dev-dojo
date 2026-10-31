# Solution — Classify without Leakage

## The implementation

```python
import numpy as np
import pandas as pd
from sklearn.pipeline import Pipeline
from sklearn.compose import ColumnTransformer
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import LogisticRegression


def build_pipeline(X_train, y_train):
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

On the verifier's dataset this scores weighted F1 ≈ 0.895.

## Why each piece is correct

**`feature_cols = [c for c in X_train.columns if c != 'leaky']`**

This line is the fix for Bug 1 (feature leakage). By building the list from the training DataFrame's actual columns, we get `['f0', 'f1', ..., 'f14']` — the 15 real features — regardless of what other columns exist. When `pipeline.predict(X_test_clean)` is called on data without `'leaky'`, the `ColumnTransformer` references only `feature_cols`. Since `'leaky'` is not in `feature_cols`, it is never accessed, and no `KeyError` is raised.

If instead you had written `StandardScaler()` directly (acting on all columns), the transformer would fit on all 16 columns including `'leaky'`. At predict time, X_test has only 15 columns — the shape mismatch causes a `ValueError`.

**`ColumnTransformer([('scale', StandardScaler(), feature_cols)])`**

`ColumnTransformer` is sklearn's mechanism for applying different transformations to different column subsets of a DataFrame. Passing a list of column names (strings) triggers pandas-style selection. Passing integer indices triggers positional selection. Always prefer column names when working with DataFrames — positional selection breaks if column order changes.

The output of `ColumnTransformer` is a NumPy array of the transformed columns. The downstream classifier (`LogisticRegression`) receives a 2-D array of shape `(n_samples, 15)`.

**`Pipeline([('prep', preprocessor), ('model', LogisticRegression(...))])`**

This is the fix for Bug 2 (preprocessing leakage). When `pipe.fit(X_train, y_train)` is called, sklearn runs `preprocessor.fit_transform(X_train)` — the `StandardScaler` inside the `ColumnTransformer` is fit only on `X_train`. When `pipe.predict(X_test_clean)` is called, sklearn runs `preprocessor.transform(X_test_clean)` using the training-time mean/std stored during `fit`. The test set's statistics never influence the scaler.

**`LogisticRegression(max_iter=1000, random_state=42)`**

Default `max_iter=100` can cause convergence warnings on this dataset. Setting `max_iter=1000` ensures the solver converges cleanly. The `random_state` makes the result deterministic (solver uses a random tie-breaking in some paths).

## Alternative classifiers that also pass

```python
# RandomForestClassifier — no scaling needed but Pipeline is still correct
from sklearn.ensemble import RandomForestClassifier
pipe = Pipeline([
    ('prep',  ColumnTransformer([('scale', StandardScaler(), feature_cols)])),
    ('model', RandomForestClassifier(n_estimators=100, random_state=42)),
])

# GradientBoostingClassifier
from sklearn.ensemble import GradientBoostingClassifier
pipe = Pipeline([
    ('prep',  ColumnTransformer([('scale', StandardScaler(), feature_cols)])),
    ('model', GradientBoostingClassifier(random_state=42)),
])
```

## What the verifier actually checks

1. `build_pipeline` returns an `sklearn.pipeline.Pipeline`.
2. `pipeline.predict(X_test_clean)` succeeds — no `KeyError` or `ValueError` — confirming `'leaky'` is not referenced.
3. `f1_score(y_test, y_pred, average='weighted') >= 0.80` on the clean test set.
4. Same pipeline architecture achieves F1 ≥ 0.80 on a second independent dataset.
5. The pipeline has at least two steps.

## The inflated score you avoided

The `show_bad_example()` function in `solution.py` reports F1 ≈ 0.98 using the leaky setup. A real model on the same data without the leaky column scores ≈ 0.89. The difference (0.98 vs 0.89) is the leakage bonus — it would disappear completely in production where `'leaky'` does not exist.

If you remove the leaky feature but keep the preprocessing leakage (Bug 2 only), the boost is smaller — maybe 0.5–1% on this iid dataset — but it compounds in cross-validation: your model selection is making decisions based on inflated fold scores, and you will systematically pick models that happen to benefit more from the leakage, not models that genuinely generalise.

## Run it yourself

```bash
cd ~/.kube-dojo-work/05-classify-without-leakage
. .venv/bin/activate
.venv/bin/pytest tests/ -v
bash courses/course-21-data-science-python/challenges/05-classify-without-leakage/verify.sh
```
