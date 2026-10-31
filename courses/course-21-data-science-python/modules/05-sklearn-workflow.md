# The scikit-learn Workflow

> **Module 05 · Course 21** — scikit-learn ships with one of the most elegant API contracts in open-source Python. Learn it once and every algorithm — from linear regression to gradient-boosted trees — slots in identically. This module covers that contract, the preprocessing toolkit, Pipelines, and the regression/classification algorithms you'll actually use at work.

You've done some ML before. The goal here is not "what is a random forest" but rather: why does scikit-learn's design make production code safe, what are the exact failure modes in the API, and how do you build a pipeline that's correct from day one.

---

## The Three Core Interfaces

Every scikit-learn object is one (or more) of three things. Knowing which one tells you exactly what methods it has and what it transforms.

```
┌──────────────────────────────────────────────────────────────────────┐
│  Estimator                                                           │
│  fit(X, y=None) → self                                              │
│  • learns parameters from data and stores them on self              │
│  • y=None for unsupervised (clustering, PCA)                        │
│                                                                      │
│    ┌────────────────────────────┐                                    │
│    │  Transformer (is-a Estimator)                                   │
│    │  transform(X) → X_new                                          │
│    │  fit_transform(X) → fit(X).transform(X) (one-shot)             │
│    │  Examples: StandardScaler, OneHotEncoder, PCA                  │
│    └────────────────────────────┘                                    │
│                                                                      │
│    ┌────────────────────────────┐                                    │
│    │  Predictor (is-a Estimator)                                     │
│    │  predict(X) → y                                                │
│    │  predict_proba(X) → probability matrix (classifiers)           │
│    │  score(X, y) → default metric (R² or accuracy)                 │
│    │  Examples: LinearRegression, RandomForestClassifier            │
│    └────────────────────────────┘                                    │
└──────────────────────────────────────────────────────────────────────┘
```

The contract enforces a critical invariant: **`transform` must be called with the same feature shape that was seen during `fit`.** If you fit a scaler on 10 features and then transform 11, it errors immediately. This is intentional — the library is pushing you toward writing code that fails loudly at the boundary.

### The fit/transform asymmetry

The most common beginner mistake is calling `fit_transform` on the test set. Correct pattern:

```python
from sklearn.preprocessing import StandardScaler

scaler = StandardScaler()
X_train_scaled = scaler.fit_transform(X_train)   # fit AND transform
X_test_scaled  = scaler.transform(X_test)         # transform ONLY — no new fit

# What fit_transform does:
# scaler.fit(X_train)           → compute mean_ and scale_ from training data
# scaler.transform(X_train)     → (X - mean_) / scale_

# Why transform-only on test:
# The test set must be scaled by the SAME mean and std from training.
# If you refit on test you are using future information — that is data leakage.
```

`scaler.mean_` and `scaler.scale_` are stored on the fitted object. You can inspect them:

```python
import numpy as np
print(scaler.mean_)      # per-feature mean computed from X_train
print(scaler.scale_)     # per-feature std computed from X_train
```

---

## Train / Test Split

```python
from sklearn.model_selection import train_test_split

X_train, X_test, y_train, y_test = train_test_split(
    X, y,
    test_size=0.2,       # 20% held out
    random_state=42,     # reproducible shuffle
    stratify=y,          # preserves class proportions — use this for classification
)
```

`stratify=y` is non-negotiable for imbalanced classification datasets. Without it a random split might put all the positive examples in the test set.

> **For time-series data, never use random split.** The test set must be strictly later in time. Use `sklearn.model_selection.TimeSeriesSplit` instead — it enforces the temporal boundary.

---

## Preprocessing

### Scaling

| Scaler | Formula | Use when |
|--------|---------|----------|
| `StandardScaler` | `(x − μ) / σ` | Features roughly Gaussian; most of the time |
| `MinMaxScaler` | `(x − min) / (max − min)` | Need values in [0, 1]; neural networks |
| `RobustScaler` | `(x − median) / IQR` | Outliers present — IQR ignores them |
| `MaxAbsScaler` | `x / max(|x|)` | Sparse data — does not shift, preserves zeros |

```python
from sklearn.preprocessing import StandardScaler, RobustScaler

# StandardScaler is the safe default for tree-free models
sc = StandardScaler()
X_train_sc = sc.fit_transform(X_train)

# RobustScaler when you have outliers you cannot drop
rs = RobustScaler()
X_train_rs = rs.fit_transform(X_train)
```

Tree-based models (RandomForest, GradientBoosting) are invariant to monotone feature scaling — they split on thresholds, not magnitudes. Scaling does not hurt them, but it's not required. Distance-based models (SVM, KNN, logistic regression with large feature variance) *need* scaling.

### Encoding Categorical Features

```python
from sklearn.preprocessing import OrdinalEncoder, OneHotEncoder

# OrdinalEncoder — converts categories to integers 0, 1, 2, ...
# DANGER: implies an ordinal relationship that may not exist
# Use only when order genuinely matters (e.g. 'low' < 'medium' < 'high')
oe = OrdinalEncoder(categories=[['low', 'medium', 'high']])
oe.fit_transform(df[['priority']])

# OneHotEncoder — the safe default for nominal categories
# sparse_output=False returns a dense array (scikit-learn >=1.2)
ohe = OneHotEncoder(sparse_output=False, handle_unknown='ignore')
ohe.fit(X_train[['city']])
# fit learns: ['Bengaluru', 'Delhi', 'Mumbai']
# transform creates three binary columns

# handle_unknown='ignore' → unseen categories become all-zeros at test time
# (the alternative, 'error', crashes in production — never do it)
```

> **`handle_unknown='ignore'` is your production safety valve.** Without it, a category that appears in test data but not training data raises `ValueError`. At SAP, a vendor category change mid-deployment would break every score call. Always set it.

### Imputation

```python
from sklearn.impute import SimpleImputer

# Numeric: replace NaN with column mean
imp_num = SimpleImputer(strategy='mean')   # also: median, most_frequent, constant

# Categorical: replace NaN with most frequent value
imp_cat = SimpleImputer(strategy='most_frequent')

# KNN imputation — uses k nearest complete rows to estimate the missing value
from sklearn.impute import KNNImputer
imp_knn = KNNImputer(n_neighbors=5)
```

The imputer's `statistics_` attribute stores the value each column will be imputed with:

```python
imp_num.fit(X_train_numeric)
print(imp_num.statistics_)   # one value per column
```

Again: fit only on training data, transform both train and test.

---

## Pipelines and ColumnTransformer

### Why Pipeline exists

Without Pipeline, preprocessing and model are separate objects. Every call to score or predict requires you to manually apply all transformations first — and you will forget.

```python
# Fragile pattern — don't do this
scaler.fit(X_train)
X_train_s = scaler.transform(X_train)
model.fit(X_train_s, y_train)

X_test_s = scaler.transform(X_test)   # easy to forget or miscode
model.predict(X_test_s)
```

With Pipeline, the chain is a single object: fitting the pipeline fits every step in order, and predicting applies all transformations automatically.

```python
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import LogisticRegression

pipe = Pipeline([
    ('scaler', StandardScaler()),
    ('model',  LogisticRegression(max_iter=1000)),
])

pipe.fit(X_train, y_train)      # fit scaler, then fit model on scaled data
pipe.predict(X_test)            # scaler.transform(X_test) → model.predict automatically
pipe.score(X_test, y_test)      # accuracy for classifiers, R² for regressors
```

All cross-validation and hyperparameter search (`GridSearchCV`) work on a Pipeline directly — transformations are refit inside each fold, preventing leakage.

### ColumnTransformer — different preprocessing per column type

Real data has mixed types: some columns are numeric, some are categorical, some need imputation before encoding.

```python
from sklearn.compose import ColumnTransformer
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler, OneHotEncoder
from sklearn.impute import SimpleImputer

numeric_features = ['age', 'salary', 'tenure_months']
categorical_features = ['department', 'city', 'role_level']

numeric_pipeline = Pipeline([
    ('imputer', SimpleImputer(strategy='median')),
    ('scaler',  StandardScaler()),
])

categorical_pipeline = Pipeline([
    ('imputer', SimpleImputer(strategy='most_frequent')),
    ('encoder', OneHotEncoder(sparse_output=False, handle_unknown='ignore')),
])

preprocessor = ColumnTransformer([
    ('num', numeric_pipeline,         numeric_features),
    ('cat', categorical_pipeline,     categorical_features),
])
```

Then the full model:

```python
from sklearn.ensemble import GradientBoostingClassifier

full_pipeline = Pipeline([
    ('preprocessor', preprocessor),
    ('model',        GradientBoostingClassifier(n_estimators=200, random_state=42)),
])

full_pipeline.fit(X_train, y_train)
full_pipeline.predict_proba(X_test)   # probabilities, not just class labels
```

The ColumnTransformer step concatenates the numeric and categorical outputs horizontally, producing the full feature matrix the model receives. You can inspect its output shape:

```python
X_transformed = preprocessor.fit_transform(X_train)
print(X_transformed.shape)   # (n_samples, n_numeric + n_ohe_categories)
```

---

## Regression Algorithms

### Linear Regression

```python
from sklearn.linear_model import LinearRegression, Ridge, Lasso, ElasticNet

lr = LinearRegression()
lr.fit(X_train, y_train)

print(lr.coef_)       # one coefficient per feature
print(lr.intercept_)  # the bias term

# Ridge: L2 regularization — shrinks all coefficients toward zero
ridge = Ridge(alpha=1.0)   # higher alpha = stronger regularization

# Lasso: L1 regularization — drives some coefficients exactly to zero (feature selection)
lasso = Lasso(alpha=0.1)

# ElasticNet: mix of L1 and L2
en = ElasticNet(alpha=0.1, l1_ratio=0.5)
```

> **When to regularize.** Linear regression overfits when features outnumber samples or features are correlated (multicollinearity). Ridge handles multicollinearity well; Lasso does feature selection; ElasticNet handles correlated-feature groups. Start with Ridge unless you explicitly want sparse coefficients.

### Decision Tree Regressor

```python
from sklearn.tree import DecisionTreeRegressor

dt = DecisionTreeRegressor(
    max_depth=5,             # limit tree depth — crucial to prevent overfit
    min_samples_leaf=10,     # no leaf smaller than 10 samples
    random_state=42,
)
dt.fit(X_train, y_train)

# Feature importances: mean decrease in impurity per feature
import pandas as pd
importances = pd.Series(dt.feature_importances_, index=feature_names).sort_values(ascending=False)
```

An unconstrained decision tree (`max_depth=None`) will memorize the training set perfectly — R²=1.0 on train, terrible on test. Always set `max_depth` or `min_samples_leaf`.

### Ensemble Methods: RandomForest and GradientBoosting

```
Bagging (Random Forest)              Boosting (Gradient Boosting)
────────────────────────             ────────────────────────────
 fit N trees in parallel             fit trees sequentially
 each on a bootstrap sample          each corrects the previous tree's errors
 average their predictions           weighted sum of predictions

 → reduces variance                  → reduces bias
 → robust to overfitting             → can overfit if n_estimators too high
 → embarrassingly parallel           → sequential, slower to train
```

```python
from sklearn.ensemble import RandomForestRegressor, GradientBoostingRegressor

rf = RandomForestRegressor(
    n_estimators=200,        # more trees = lower variance (diminishing returns after ~300)
    max_depth=None,          # trees grow to purity — bagging handles variance
    max_features='sqrt',     # each split considers sqrt(n_features) candidates
    n_jobs=-1,               # use all CPU cores
    random_state=42,
)
rf.fit(X_train, y_train)

gb = GradientBoostingRegressor(
    n_estimators=300,
    max_depth=4,             # shallow trees — gradient boosting prefers them
    learning_rate=0.05,      # smaller = more robust, need more n_estimators
    subsample=0.8,           # stochastic GB — slightly better generalization
    random_state=42,
)
gb.fit(X_train, y_train)
```

---

## Classification Algorithms

### Logistic Regression

```python
from sklearn.linear_model import LogisticRegression

lr = LogisticRegression(
    C=1.0,           # inverse of regularization strength — higher C = less regularization
    max_iter=1000,   # default 100 is often not enough; bump to 1000
    solver='lbfgs',  # good default for small-medium data
    class_weight='balanced',  # compensates for class imbalance automatically
)
lr.fit(X_train, y_train)

# predict_proba returns [P(class=0), P(class=1)] per sample
proba = lr.predict_proba(X_test)
print(proba[:5])   # [[0.23, 0.77], [0.91, 0.09], ...]
```

Despite the name, logistic regression is a classifier. `predict` returns class labels; `predict_proba` returns calibrated probabilities. The probability threshold defaults to 0.5 — you can tune it for imbalanced problems.

### RandomForestClassifier

```python
from sklearn.ensemble import RandomForestClassifier

rfc = RandomForestClassifier(
    n_estimators=200,
    max_depth=None,
    class_weight='balanced',   # adjust sample weights to equalize class frequency
    n_jobs=-1,
    random_state=42,
)
rfc.fit(X_train, y_train)
rfc.predict_proba(X_test)
```

### GradientBoostingClassifier / HistGradientBoosting

```python
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.ensemble import HistGradientBoostingClassifier  # faster, supports NaN natively

hgb = HistGradientBoostingClassifier(
    max_iter=300,
    max_depth=4,
    learning_rate=0.05,
    random_state=42,
    # class_weight not supported — use sample_weight in fit instead
)
hgb.fit(X_train, y_train)

# HistGradientBoosting is 10–100x faster on large data (uses histogram binning)
# and handles NaN natively — no imputation step needed
```

> **HistGradientBoosting vs GradientBoosting.** For datasets above ~10k rows, `HistGradientBoostingClassifier` is almost always the right choice: histogram binning reduces memory and speeds up split finding dramatically. It also eliminates the need for a separate imputation step since NaN is treated as a valid bin.

---

## Debugging the scikit-learn Workflow

### Bug 1: Fitting the preprocessor on test data

```python
# WRONG — test set contamination
scaler = StandardScaler()
X_train_s = scaler.fit_transform(X_train)
X_test_s  = scaler.fit_transform(X_test)    # BUG: refits on test

# CORRECT
X_train_s = scaler.fit_transform(X_train)
X_test_s  = scaler.transform(X_test)        # uses training mean/std
```

The symptom: your test performance looks better than it really is (the test distribution was used to set the scaling parameters). Caught in code review. Fixed by always using Pipeline.

### Bug 2: Forgetting to scale before a distance-based model

```python
# Symptom: LogisticRegression or SVM performs terribly despite clean data
# Cause: feature 'salary' has range [0, 200000] while 'age' has range [18, 65]
# The model is dominated by salary gradients

# Diagnosis: check feature variances
import numpy as np
print(np.var(X_train, axis=0))   # one wildly large number → that feature dominates

# Fix: add StandardScaler to your pipeline
pipe = Pipeline([
    ('scaler', StandardScaler()),
    ('model',  LogisticRegression()),
])
```

Tree-based models are immune (splits are threshold comparisons, not magnitude-sensitive), but anything using gradient descent or distance — logistic regression, SVM, KNN, PCA — will be badly hurt.

### Bug 3: Category leakage via target encoding

```python
# WRONG: compute target-encoded means BEFORE split
df['dept_mean_target'] = df.groupby('department')['churn'].transform('mean')
X = df.drop('churn', axis=1)
y = df['churn']
X_train, X_test, y_train, y_test = train_test_split(X, y)
# BUG: test set rows already contain information from y computed on the full dataset

# CORRECT: compute target encoding only inside the training fold
# Use sklearn TargetEncoder (>=1.3) or compute inside a Pipeline
from sklearn.preprocessing import TargetEncoder
te = TargetEncoder(smooth='auto')
# fit on X_train, y_train; transform test separately
```

Target encoding is one of the most powerful feature engineering techniques and one of the easiest to leak. The safe pattern: always compute target statistics inside the Pipeline so cross-validation refits them per fold.

### Bug 4: Pipeline `.fit` called on the wrong variable

```python
# Easy to write:
pipe.fit(X, y)           # fits on the full dataset — no held-out test set

# Should be:
pipe.fit(X_train, y_train)
pipe.score(X_test, y_test)
```

If your reported score is inexplicably high (R²=0.99 on what should be a hard problem), check that you're not calling `score(X_train, y_train)` or fitting on the full data.

---

## Checkpoint

You're ready to move on when you can answer these without looking:

1. What three methods does every scikit-learn Estimator expose? What's the difference between a Transformer and a Predictor?
2. You have a dataset with 3 numeric features and 2 categorical features. Sketch the ColumnTransformer structure you'd use.
3. When should you use `RobustScaler` instead of `StandardScaler`?
4. What does `handle_unknown='ignore'` do in `OneHotEncoder`, and why is it required for production deployments?
5. A decision tree on your training data has R²=1.0 and R²=0.52 on test. What's wrong, and what two hyperparameters fix it?
6. Describe in one sentence the difference between Random Forest and Gradient Boosting in terms of what error they reduce.
7. You get a `ConvergenceWarning` from `LogisticRegression`. What do you set?
8. You check `scaler.mean_` after fitting — what should it equal? What would tell you you accidentally re-fit on the test set?

➡ Next: **Module 06 — Model Evaluation & Validation.** A great in-sample score is meaningless without the right evaluation framework. That module covers metrics, cross-validation, the bias-variance tradeoff, and data leakage in full.
