# Solution — Train a Regressor

Complete `solution.py` with explanations.

## The implementation

```python
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import Ridge


def build_pipeline(X_train, y_train):
    pipe = Pipeline([
        ('scaler', StandardScaler()),
        ('model',  Ridge(alpha=1.0)),
    ])
    pipe.fit(X_train, y_train)
    return pipe
```

This is the minimal correct solution. On the verifier's dataset it scores R² ≈ 0.935.

## Why each piece is required

**`Pipeline([('scaler', ...), ('model', ...)])`**

The Pipeline chains two transformations: first the scaler normalises each feature column to zero-mean unit-variance, then Ridge fits on the scaled features. When you call `pipe.fit(X_train, y_train)`, sklearn calls `StandardScaler.fit_transform(X_train)` internally, then passes the result to `Ridge.fit`. When you call `pipe.predict(X_test)`, sklearn calls `StandardScaler.transform(X_test)` using the training mean/std, then calls `Ridge.predict`. The scaler never sees the test distribution — that is the whole point.

**`StandardScaler()`**

Ridge regression minimises:

```
‖Xβ - y‖² + α ‖β‖²
```

The regulariser `α ‖β‖²` penalises all coefficients equally in their current units. If one feature has values in the thousands and another in the range [0, 1], the regulariser effectively ignores the small-magnitude feature while heavily penalising the large-magnitude one. Scaling removes this bias. The same logic applies to any model whose loss or distance is Euclidean.

**`Ridge(alpha=1.0)` vs `LinearRegression()`**

Both work on this dataset. `LinearRegression` is OLS — no regularisation — and gets R² ≈ 0.934. `Ridge` with `alpha=1.0` is almost identical here because the dataset has only 10 features and 400 training samples (OLS is not ill-conditioned). As the feature count grows or features become collinear, Ridge stays stable while OLS can diverge.

## Alternative models that also pass

Any of these will exceed R² = 0.80 on this dataset:

```python
# Option A: RandomForestRegressor (no scaling needed, but Pipeline is still correct)
from sklearn.ensemble import RandomForestRegressor
pipe = Pipeline([
    ('scaler', StandardScaler()),
    ('model',  RandomForestRegressor(n_estimators=100, random_state=42)),
])

# Option B: GradientBoostingRegressor
from sklearn.ensemble import GradientBoostingRegressor
pipe = Pipeline([
    ('scaler', StandardScaler()),
    ('model',  GradientBoostingRegressor(random_state=42)),
])

# Option C: SVR with RBF kernel (needs scaling)
from sklearn.svm import SVR
pipe = Pipeline([
    ('scaler', StandardScaler()),
    ('model',  SVR(kernel='rbf', C=10, epsilon=0.1)),
])
```

## What the verifier actually checks

1. `build_pipeline` returns an `sklearn.pipeline.Pipeline` instance.
2. The pipeline has at least two steps.
3. `pipeline.predict(X_test).shape == y_test.shape`.
4. `r2_score(y_test, pipeline.predict(X_test)) >= 0.80`.
5. The same pipeline architecture generalises to a second independent dataset (different `random_state`) — confirming the model is not somehow overfitted to the exact test split.

## Run it yourself

```bash
cd ~/.kube-dojo-work/04-train-a-regressor
. .venv/bin/activate
.venv/bin/pytest tests/ -v
bash courses/course-21-data-science-python/challenges/04-train-a-regressor/verify.sh
```
