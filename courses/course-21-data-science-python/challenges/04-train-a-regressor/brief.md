# Train a Regressor

The ML team's pricing service relies on a hand-coded formula maintained by one engineer who is leaving next week. The formula has accumulated if-else branches for a dozen edge cases and has never been benchmarked against actual data. Your ticket:

> *"Replace the legacy formula with a properly trained regression model. Use a sklearn Pipeline so scaling is part of the model, not a separate preprocessing step. CI checks R² on a 20% held-out split."*

## Why Pipelines, not standalone scalers

Before writing a single line of model code, understand the trap you are avoiding.

A common beginner pattern:

```python
scaler = StandardScaler()
X_scaled = scaler.fit_transform(X)          # ← fits scaler on ALL data
X_train, X_test, y_train, y_test = train_test_split(X_scaled, ...)
model.fit(X_train, y_train)
```

This looks harmless but it is **data leakage at the preprocessing layer**. The scaler's mean and standard deviation are computed from the test set rows too. The test set is supposed to be unseen data that simulates production; if its statistics have already leaked into the scaler, your validation metrics are optimistic. The model was indirectly "told" things about the test set it should not know.

The correct pattern:

```
Pipeline([
    ('scaler', StandardScaler()),
    ('model',  Ridge()),
])
pipe.fit(X_train, y_train)        # scaler sees only X_train
pipe.predict(X_test)              # test data scaled with training stats only
```

Inside a Pipeline, `fit()` calls each step's `fit_transform()` in sequence on the training data, and `predict()` calls each step's `transform()` on new data — using parameters set during `fit`. The scaler never sees the test distribution directly.

This distinction is invisible when train and test come from the same iid distribution, but it is the difference between a trustworthy held-out score and an inflated one in real datasets where the test distribution shifts slightly.

```
          Training phase                 Prediction phase
          ──────────────                 ────────────────
X_train ──▶ StandardScaler.fit_transform ──▶ Ridge.fit
                  │ stores μ, σ
X_test  ──────────▶ StandardScaler.transform ──▶ Ridge.predict
                  (uses training μ, σ only!)
```

## Why feature scaling matters for regression

Not all regression models need scaling, but many do:

| Model | Sensitive to scale? | Why |
|-------|---------------------|-----|
| LinearRegression | Yes (gradient / cond. number) | Columns with large magnitudes dominate the normal equations |
| Ridge / Lasso | Yes — the regularizer λ is in feature units | Without scaling, λ punishes large-magnitude features less |
| SVR | Yes | Kernel distances are Euclidean |
| RandomForestRegressor | No | Splits are rank-based, invariant to monotone transforms |
| GradientBoostingRegressor | No | Same as RF |

Putting a `StandardScaler` (or `MinMaxScaler`, `RobustScaler`) in the Pipeline is safe for all models and mandatory for the linear family.

## The dataset

The verifier generates its data with:

```python
from sklearn.datasets import make_regression
from sklearn.model_selection import train_test_split

X, y = make_regression(
    n_samples=500, n_features=10, n_informative=8,
    noise=30, random_state=42
)
X_train, X_test, y_train, y_test = train_test_split(
    X, y, test_size=0.2, random_state=42
)
```

`make_regression` produces a linearly-separable target with controlled noise. Ten input features; eight of them are informative; two are noise dimensions. With `noise=30`, a well-fitted linear model achieves R² ≈ 0.93 on the held-out split. The verifier's threshold is **R² ≥ 0.80**, which any reasonable model with scaling will exceed.

## What R² actually measures

```
R² = 1 - SS_res / SS_tot
   = 1 - Σ(y - ŷ)² / Σ(y - ȳ)²
```

- **R² = 1.0** → perfect predictions; all variance explained.
- **R² = 0.0** → the model does no better than predicting the mean of y for every point.
- **R² < 0** → the model is worse than the mean baseline (possible with a bad model on test data).

For this dataset, a model that scores below 0.80 is effectively broken — it means you are explaining less than 80% of the target variance when the data is genuinely close to linear. Common reasons for a low score:

1. The model is not being fit at all (stub raises `NotImplementedError`).
2. The scaler is fit outside the pipeline on all data, but this only inflates training R², not test R².
3. The model has severe hyperparameter issues (e.g., `alpha=1e9` in Ridge collapses the weights to near-zero).

## Prerequisites

```bash
cd ~/.kube-dojo-work/04-train-a-regressor
python3 -m venv .venv && . .venv/bin/activate
pip install pytest numpy scikit-learn
```

## Work directory

`setup.sh` plants:

```
~/.kube-dojo-work/04-train-a-regressor/
├── solution.py          # implement build_pipeline() here
└── tests/
    └── test_sample.py   # two visible tests you can run locally
```

## Mission

Implement `build_pipeline(X_train, y_train)` in `solution.py`:

- **Input:** `X_train` — a NumPy array of shape `(400, 10)`; `y_train` — a 1-D NumPy array of 400 regression targets.
- **Output:** a **fitted** `sklearn.pipeline.Pipeline` that includes at least one scaler step and one regression estimator step.
- The verifier calls `pipeline.predict(X_test)` on the held-out 100 rows and asserts `r2_score(y_test, y_pred) >= 0.80`.

Any regression estimator works (LinearRegression, Ridge, Lasso, RandomForestRegressor, GradientBoostingRegressor, SVR, …). The key requirement is that the Pipeline is correctly structured and actually fitted.

## Verify

```bash
bash courses/course-21-data-science-python/challenges/04-train-a-regressor/verify.sh
```

R² ≥ 0.80 on the hidden test split → flag printed.
