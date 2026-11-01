# Leakage-Free Feature Pipeline

A code-review comment on a PR: *"Your model hits 0.97 accuracy on the test set but only 0.72 in staging. The baseline was 0.73. Something is wrong with the evaluation, not the model."*

The culprit: data leakage. The feature pipeline fitted its scaler on the full dataset before the train/test split, so the test set's statistics silently informed the training transform. Add a `future_score` column that's derived from the target, and you've also got target leakage — the model is effectively peeking at the answer.

## Context

`setup.sh` plants the scaffold in your work directory:

```
~/.kube-dojo-work/02-leakage-free-features/
└── features.py   # leaky baseline + build_features() stub
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/02-leakage-free-features
python3 -m venv .venv && . .venv/bin/activate
pip install scikit-learn numpy pandas pytest
```

## Mission

Implement `build_features(df, test_size, random_state)` in `features.py`:

| Requirement | Detail |
|-------------|--------|
| Drop leaky columns | Remove every column in `LEAKY_COLS` before any split |
| Split first | Separate rows into train/test **before** fitting any transform |
| Fit on train only | Call `scaler.fit(X_train)`, never `scaler.fit(X)` or `scaler.fit_transform(X)` |
| Transform both | Apply the fitted scaler to both X_train and X_test |
| Return signature | `(X_train_scaled, X_test_scaled, y_train, y_test, scaler)` |

The verifier checks that `scaler.mean_` matches the train-partition statistics precisely (to 1e-6 tolerance) and does **not** match the full-dataset statistics.

## Two flavours of leakage in this data

**Preprocessing leakage** (`build_features_leaky` line 3): `StandardScaler.fit_transform(X)` computes mean and std over all 500 rows, including the 100 that become the test set. When you later evaluate on those 100 rows, the scaler's learned statistics already "know" their values. Your normalised test features are no longer out-of-sample.

**Target leakage** (`future_score` column): this feature equals `y * 10 + ε`. A model that sees it during training learns to use it as a near-perfect shortcut. In production the column won't exist (it was generated from the target you're trying to predict), so the model will have learned something it can never use — resulting in the 0.97 → 0.72 accuracy cliff.

## Verify

```bash
bash courses/course-24-mlops/challenges/02-leakage-free-features/verify.sh
```

All four tests green → flag printed.
