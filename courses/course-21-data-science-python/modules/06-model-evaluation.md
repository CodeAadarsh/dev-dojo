# Model Evaluation & Validation

> **Module 06 · Course 21** — The most dangerous number in machine learning is a training accuracy you don't question. This module is about building the mental model and tooling to know whether your model actually works — and knowing the three or four ways it can lie to you while appearing to work.

A model that achieves 99% accuracy in development and fails in production is not a model problem. It is an evaluation methodology problem. This module fixes that.

---

## Regression Metrics

You have a continuous target (salary, latency, revenue). Three metrics tell different parts of the story.

```
                          Residuals: y_true - y_pred
                          ┌─────────────────────────────────────┐
                      15 ─┤                    *                │
                      10 ─┤          *    *                     │
                       5 ─┤  *                                  │
                       0 ─┼──────────────────────────────────── │
                      -5 ─┤               *                     │
                     -10 ─┤                    *                │
                          └─────────────────────────────────────┘
                              MAE sees the average absolute size
                              RMSE penalizes large residuals harder
                              R² asks: how much better than always predicting mean?
```

### Mean Absolute Error (MAE)

```python
from sklearn.metrics import mean_absolute_error

mae = mean_absolute_error(y_test, y_pred)
# Same units as the target. If predicting salary in INR: MAE = ₹45,000
# means on average your predictions are off by ₹45,000.
```

MAE is **robust to outliers** because it treats a ₹1M error the same proportionally as ten ₹100k errors. Use it when outliers are meaningful signals you don't want to suppress.

### Root Mean Squared Error (RMSE)

```python
from sklearn.metrics import root_mean_squared_error   # sklearn >= 1.4

# or manually for older sklearn:
import numpy as np
from sklearn.metrics import mean_squared_error
rmse = np.sqrt(mean_squared_error(y_test, y_pred))
```

RMSE **squares each residual before averaging**, then takes the square root. A prediction that is off by 10 contributes 100 to the sum; one off by 100 contributes 10,000. This makes RMSE sensitive to large errors — which is exactly what you want when large errors are costly (predicting server provisioning need: a 10x overprovision is much worse than a 2x).

RMSE ≥ MAE always, with equality only when all errors are identical. A large RMSE/MAE ratio means you have a few very bad predictions pulling the RMSE up.

### R² (Coefficient of Determination)

```python
from sklearn.metrics import r2_score

r2 = r2_score(y_test, y_pred)
# R² = 1 - (SS_residual / SS_total)
# SS_total = variance of y_test times n (how much variance there is to explain)
# R² = 1.0 → perfect predictions
# R² = 0.0 → model is no better than always predicting the mean
# R² < 0.0 → model is *worse* than always predicting the mean (possible for test set)
```

R² is scale-free — it tells you the fraction of variance explained, which lets you compare across datasets with different units. A model with R²=0.82 explains 82% of the variation in the target.

> **R² on test vs train.** A train R²=0.98 with test R²=0.55 is a severe overfit. A train R²=0.72 with test R²=0.68 is healthy generalization. The gap matters more than the absolute value.

---

## Classification Metrics

A single accuracy number is almost never sufficient. You need to understand *which kinds of errors your model makes*.

### The Confusion Matrix

```
                  Predicted
                  Negative    Positive
Actual  Negative     TN           FP     ← False Alarm (Type I)
        Positive     FN           TP     ← Catch
                     ↑
               Miss (Type II)
```

```python
from sklearn.metrics import confusion_matrix, ConfusionMatrixDisplay
import matplotlib.pyplot as plt

cm = confusion_matrix(y_test, y_pred)
disp = ConfusionMatrixDisplay(confusion_matrix=cm, display_labels=['No Churn', 'Churn'])
disp.plot()
plt.show()
```

### Accuracy, Precision, Recall, F1

```python
from sklearn.metrics import accuracy_score, precision_score, recall_score, f1_score

# Accuracy: (TP + TN) / total
# Misleading when classes are imbalanced.
# A model predicting "no fraud" always has 99.9% accuracy on a 0.1% fraud dataset.
acc = accuracy_score(y_test, y_pred)

# Precision: TP / (TP + FP) — of all predicted positives, how many were correct?
# High precision → few false alarms
prec = precision_score(y_test, y_pred)

# Recall (Sensitivity): TP / (TP + FN) — of all actual positives, how many did we catch?
# High recall → few misses
rec = recall_score(y_test, y_pred)

# F1: harmonic mean of precision and recall
# Useful single number when you want to balance the two
f1 = f1_score(y_test, y_pred)
```

Choose your metric based on the cost of each error type:

| Domain | Optimize for | Because |
|--------|-------------|---------|
| Fraud detection | Recall | Missing fraud is catastrophic |
| Spam filter | Precision | False positives annoy users more than missed spam |
| Medical screening | Recall | Missed diagnosis is worse than a follow-up test |
| Content recommendation | F1 | Both irrelevant content and missing content matter |

### ROC-AUC

```python
from sklearn.metrics import roc_auc_score, roc_curve

# AUC = Area Under the ROC Curve
# Measures the model's ability to rank positives above negatives
# across ALL decision thresholds simultaneously

# Requires probability scores, not class labels
y_proba = model.predict_proba(X_test)[:, 1]   # probability of the positive class
auc = roc_auc_score(y_test, y_proba)

# AUC = 1.0 → perfect ranking
# AUC = 0.5 → random (diagonal line)
# AUC < 0.5 → model is consistently wrong (swap predict logic)

fpr, tpr, thresholds = roc_curve(y_test, y_proba)
```

```
ROC Curve
TPR  1.0 ─┐           ╭──────────────
(Recall)   │       ╭───╯
           │   ╭───╯
      0.5 ─│ ╭─╯          AUC = shaded area under the curve
           │─╯ ← random classifier diagonal
      0.0 ─┴──────────────────────────
           0.0    0.5    1.0
                       FPR (False Positive Rate)
```

### Class Imbalance

When classes are heavily skewed (fraud: 0.1% positive; churn: 5% positive), the standard threshold of 0.5 is wrong.

```python
# Strategy 1: class_weight='balanced' during training
from sklearn.linear_model import LogisticRegression
model = LogisticRegression(class_weight='balanced')

# Strategy 2: adjust decision threshold
y_proba = model.predict_proba(X_test)[:, 1]
threshold = 0.3    # lower threshold → higher recall at cost of precision
y_pred_tuned = (y_proba >= threshold).astype(int)

# Strategy 3: SMOTE (synthetic minority oversampling) — from imbalanced-learn
# Only apply SMOTE inside the training fold, never before the split
from imblearn.pipeline import Pipeline as ImbPipeline
from imblearn.over_sampling import SMOTE
pipe = ImbPipeline([
    ('smote', SMOTE(random_state=42)),
    ('model', GradientBoostingClassifier()),
])

# Strategy 4: use AUC or F1 as primary metric, not accuracy
```

> **The precision-recall curve is often better than ROC for imbalanced data.** ROC's FPR denominator uses the large negative class, which can be misleadingly forgiving. `average_precision_score` summarizes the precision-recall curve as a single number.

```python
from sklearn.metrics import average_precision_score
ap = average_precision_score(y_test, y_proba)
```

---

## Cross-Validation

A single train/test split gives you one estimate of model performance. One estimate from one random seed is not reliable.

### k-Fold Cross-Validation

```python
from sklearn.model_selection import cross_val_score, KFold

kf = KFold(n_splits=5, shuffle=True, random_state=42)

scores = cross_val_score(
    pipeline,    # a Pipeline — transformations are refit inside each fold
    X, y,
    cv=kf,
    scoring='r2',
    n_jobs=-1,
)

print(f"CV R²: {scores.mean():.3f} ± {scores.std():.3f}")
# 5 independent estimates — the mean is more trustworthy than any single split
```

```
k=5 fold visualization:

Fold 1: [TEST | ─── TRAIN ─────────────────────────]
Fold 2: [──── | TEST | ───── TRAIN ─────────────────]
Fold 3: [──────────── | TEST | ── TRAIN ─────────────]
Fold 4: [──────────────────── | TEST | ── TRAIN ──────]
Fold 5: [────────────────────────────── | TEST | TRAIN]
                                               (last fold)
Each fold: fit on remaining 4/5, evaluate on held-out 1/5
```

### Stratified k-Fold

For classification, always use `StratifiedKFold`. It ensures each fold has the same class proportion as the full dataset:

```python
from sklearn.model_selection import StratifiedKFold

skf = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)
scores = cross_val_score(pipeline, X, y, cv=skf, scoring='f1')
```

Without stratification, a fold might accidentally contain very few positive examples, making the F1 estimate meaningless.

### cross_val_score vs cross_validate

```python
from sklearn.model_selection import cross_validate

results = cross_validate(
    pipeline, X, y,
    cv=skf,
    scoring=['f1', 'roc_auc', 'precision', 'recall'],
    return_train_score=True,   # compare train vs test score per fold — key for diagnosing overfit
    n_jobs=-1,
)

import pandas as pd
df = pd.DataFrame(results)
print(df[['train_f1', 'test_f1', 'train_roc_auc', 'test_roc_auc']].describe())
```

The `return_train_score=True` flag is gold for diagnosing overfit: if train score is consistently much higher than test score across all folds, the model is memorizing.

---

## The Bias-Variance Tradeoff

This is the fundamental tension in supervised learning. Every model makes these two types of errors:

```
High Bias (Underfitting)          High Variance (Overfitting)
──────────────────────────        ──────────────────────────────
Model too simple to capture       Model memorizes training noise
the true underlying pattern       instead of the signal

• High train error                 • Low train error
• High test error                  • High test error
• Train ≈ test (both bad)          • Train << test (large gap)

Fix: more features, higher         Fix: more data, simpler model,
     model complexity,                  regularization, dropout,
     remove regularization              pruning, early stopping

Example: linear model on          Example: 30-layer decision
nonlinear data                    tree with n_samples leaves
```

The validation curve makes this visual:

```python
from sklearn.model_selection import validation_curve

param_range = [1, 2, 3, 5, 7, 10, 15, 20]
train_scores, test_scores = validation_curve(
    DecisionTreeRegressor(random_state=42),
    X_train, y_train,
    param_name='max_depth',
    param_range=param_range,
    cv=5,
    scoring='r2',
)

# Plot train_scores.mean(axis=1) and test_scores.mean(axis=1) vs param_range
# The gap between them is the variance; the level is the bias
```

### Regularization

Regularization adds a penalty for complexity to the loss function:

```
# Unregularized loss:
L(w) = MSE(y, Xw)

# Ridge (L2):
L(w) = MSE(y, Xw) + α * Σwᵢ²
       ↑ fit well   ↑ stay small

# Lasso (L1):
L(w) = MSE(y, Xw) + α * Σ|wᵢ|
                        ↑ drives some wᵢ exactly to 0
```

Higher `alpha` in Ridge/Lasso = stronger regularization = simpler model. Tune it via `GridSearchCV` or `cross_val_score`.

---

## Data Leakage — The #1 Silent Killer

Data leakage means your model has access during training (or preprocessing) to information it would not have at prediction time. It produces models that evaluate brilliantly and fail catastrophically in production.

### The taxonomy of leakage

```
Type 1: Target leakage
  A feature contains direct or derived information from the target,
  but that information would not be available at predict time.
  Example: 'days_to_churn' is in the feature set when predicting churn.
  Fix: careful feature audit — ask "would I know this at predict time?"

Type 2: Train-test contamination
  Preprocessing statistics (mean, std, category frequencies, target-encoded values)
  are computed on the full dataset before the split.
  Fix: always fit preprocessing inside Pipeline or after the split.

Type 3: Temporal leakage
  You use future information to predict the past in your eval split.
  Example: random split on a time-series; test rows from 2022 have
  training neighbors from 2023.
  Fix: time-based split or TimeSeriesSplit.

Type 4: Duplicate leakage
  The same row (or near-duplicate rows) appears in both train and test.
  Example: you oversampled before splitting; SMOTE-generated rows
  that are transformations of a training point end up in test.
  Fix: split first, SMOTE inside the training fold only.
```

### The classic preprocessing-before-split bug

```python
# WRONG — the scaler sees the test data during fit
from sklearn.preprocessing import StandardScaler
scaler = StandardScaler()
X_scaled = scaler.fit_transform(X)   # entire dataset!
X_train, X_test = train_test_split(X_scaled)
# Mean and std used to scale test data were computed using test data.
# The test performance estimate is optimistic.

# CORRECT — Pipeline ensures fit happens on training fold only
pipe = Pipeline([('scaler', StandardScaler()), ('model', LinearRegression())])
cross_val_score(pipe, X, y, cv=5)   # scaler.fit is called on each training fold
```

The insidious part: the bias from this mistake is often small on balanced datasets with simple models. It grows as the preprocessing becomes more complex (target encoding, PCA) and as the dataset shrinks.

### Diagnosing suspected leakage

```python
# Signal 1: suspiciously high CV score
# Any R² > 0.95 on a real-world messy dataset deserves suspicion.
# Any AUC > 0.99 on imbalanced fraud data deserves deep investigation.

# Signal 2: score collapses completely on truly held-out data
# Hold out the last N months of data entirely before you start,
# touch it only at the very end. If your CV score is 0.85 and your
# final holdout is 0.51 — you have leakage.

# Signal 3: the most important features don't make business sense
# If 'user_id' or 'timestamp' shows up as top-3 in feature importances,
# something is wrong.

# Audit using permutation importance on test data:
from sklearn.inspection import permutation_importance
result = permutation_importance(model, X_test, y_test, n_repeats=10, random_state=42)
feat_imp = pd.Series(result.importances_mean, index=feature_names).sort_values(ascending=False)
```

---

## Debugging Evaluation

### Great CV score, terrible production

Root causes in order of likelihood:

1. **Distribution shift.** Training data is from one time period; production data is newer. The underlying pattern changed. Fix: retrain periodically, monitor feature distributions in production.
2. **Preprocessing leakage.** Fix: wrap all preprocessing in a Pipeline, verify with a true holdout.
3. **Target definition mismatch.** The label in training data is defined differently than what the production system reports. Fix: trace the label generation code end-to-end.
4. **Sample selection bias.** Training data is not a random sample of the production population. Fix: sample from the production population.

### Leakage via preprocessing before split

Symptoms:
- CV score that seems implausibly high for the complexity of the problem
- Feature importance shows one feature with 80%+ importance that shouldn't be that predictive
- Model degrades dramatically in A/B test versus CV estimate

Diagnosis workflow:
```python
# Manually verify the scaler was NOT fit on test data
print(scaler.mean_)        # should be close to X_train.mean(axis=0)
print(X_test.mean(axis=0)) # should differ from scaler.mean_ slightly
# If they are identical → you fit the scaler on X_test
```

### Wrong metric for imbalanced classes

```python
# The tell: your model gets 99.7% accuracy but your fraud team is angry
from sklearn.metrics import classification_report
print(classification_report(y_test, y_pred, target_names=['legit', 'fraud']))
#               precision  recall  f1-score  support
# legit            1.00      1.00      1.00    9970
# fraud            0.12      0.03      0.05      30
# The model is predicting 'legit' almost every time.
# Fix: class_weight='balanced', tune threshold, use F1/AUC not accuracy.
```

---

## Hyperparameter Search

```python
from sklearn.model_selection import GridSearchCV, RandomizedSearchCV

# GridSearchCV — exhaustive, every combination
param_grid = {
    'model__n_estimators': [100, 200, 300],
    'model__max_depth': [3, 4, 5],
    'model__learning_rate': [0.01, 0.05, 0.1],
}
grid_search = GridSearchCV(
    pipeline,
    param_grid,
    cv=StratifiedKFold(5, shuffle=True, random_state=42),
    scoring='roc_auc',
    n_jobs=-1,
    verbose=1,
)
grid_search.fit(X_train, y_train)
print(grid_search.best_params_)
print(grid_search.best_score_)

# Evaluate on test — only once, after search is complete
final_score = grid_search.score(X_test, y_test)
```

> **Never include the test set in hyperparameter search.** `GridSearchCV` handles the inner cross-validation automatically. The test set is touched exactly once at the very end to report final performance. If you use the test score to inform hyperparameter choices, you are overfitting to the test set — your "test" becomes a second validation set.

---

## Checkpoint

1. MAE vs RMSE: give an example where you'd prefer each, and say why.
2. A fraud model reports 99.7% accuracy. What single output from `classification_report` would tell you immediately whether to trust it?
3. What does `return_train_score=True` in `cross_validate` tell you that `cross_val_score` does not?
4. Describe in one sentence why the bias-variance tradeoff means "simpler is usually safer with small datasets."
5. Name three distinct types of data leakage. Which one is eliminated by using `Pipeline` with `cross_val_score`?
6. You wrap preprocessing in a Pipeline and still observe CV score 0.94 → production score 0.61. What are the two most likely causes?
7. When should you use `StratifiedKFold` instead of plain `KFold`?
8. A colleague uses `GridSearchCV` and then evaluates `grid_search.best_score_` as the final reported accuracy. What's wrong with this?

➡ Next: **Module 07 — Unsupervised Learning & a Capstone.** Clustering, PCA, feature engineering, and a fully worked end-to-end project tying everything together.
