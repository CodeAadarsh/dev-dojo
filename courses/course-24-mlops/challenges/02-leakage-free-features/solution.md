# Solution — Leakage-Free Feature Pipeline

## Complete `build_features()`

```python
def build_features(
    df: pd.DataFrame,
    test_size: float = 0.2,
    random_state: int = SEED,
):
    # 1. Drop leaky column(s) and the target before building X
    X = df.drop(columns=["target"] + LEAKY_COLS).values
    y = df["target"].values

    # 2. Split BEFORE any transform — the order is the whole point
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=test_size, random_state=random_state
    )

    # 3. Fit only on train
    scaler = StandardScaler()
    scaler.fit(X_train)

    # 4. Transform both partitions with the train-fitted scaler
    X_train_scaled = scaler.transform(X_train)
    X_test_scaled = scaler.transform(X_test)

    return X_train_scaled, X_test_scaled, y_train, y_test, scaler
```

## Why the order matters

**The leaky baseline's mistake, step by step:**

```
raw X (500 rows) ──► StandardScaler.fit_transform(X)  ← scaler sees test-set values
                                ↓
               X_scaled (500 rows, normalised)
                                ↓
               train_test_split(X_scaled)    ← split happens AFTER
                ↓                  ↓
           X_train              X_test     ← test was already encoded with full-data stats
```

The correct order:

```
raw X (500 rows) ──► train_test_split ──► X_train (400 rows)
                                              ↓
                                   StandardScaler.fit(X_train)  ← sees only 400 rows
                                              ↓
                               scaler.transform(X_train)   (encode train)
                               scaler.transform(X_test)    (encode test with train stats)
```

When the scaler fits on all 500 rows, its `mean_` and `scale_` incorporate the test rows. Normalising the test set with those statistics is equivalent to your test set having been "seen" by the preprocessing step — it's no longer held-out. The effect is optimistic evaluation metrics and a production cliff when you deploy.

**Why drop `future_score`:**
`future_score = y * 10 + ε`. A model that sees this column during training learns a near-perfect decision rule (`future_score > 5 → class 1`). The column doesn't exist at inference time because the target isn't known then — you're predicting it. Including it in training is learning from the answer key.

The canonical check: *can this feature be computed at prediction time without knowing the target?* If no, drop it.

## The broader lesson: Pipeline vs manual transforms

In production, wrap this pattern in `sklearn.pipeline.Pipeline`:

```python
from sklearn.pipeline import Pipeline
from sklearn.ensemble import RandomForestClassifier

pipe = Pipeline([
    ("scaler", StandardScaler()),
    ("clf", RandomForestClassifier(random_state=42, n_jobs=1)),
])
pipe.fit(X_train, y_train)     # fit() on train only, transform applied internally
pipe.score(X_test, y_test)     # transform applied with train stats — correct
```

`Pipeline.fit()` calls `fit_transform()` on all intermediate steps and `fit()` on the final estimator, all in one call and all using only the training data. When you cross-validate with `cross_val_score(pipe, X, y)`, each fold fits the scaler on its training split — impossible to do correctly without the pipeline abstraction.

## Apply and verify

```bash
cd ~/.kube-dojo-work/02-leakage-free-features
# replace build_features() in features.py with the solution above, then:
python3 -c 'from features import make_raw_df, build_features; df=make_raw_df(); print(build_features(df)[0].shape)'
bash courses/course-24-mlops/challenges/02-leakage-free-features/verify.sh
```
