# Reproducible Training

A post-mortem comment in your ML platform: *"Retraining job #342 produced a different model than #341 — same data, same code, different predictions. Root-cause unknown. We cannot ship this."*

Unreproducible training is a silent production killer. You can't diff two runs, you can't roll back safely, and you can't trust that "the same model" is actually the same model after a hotfix.

## Context

`setup.sh` plants a training scaffold in your work directory:

```
~/.kube-dojo-work/01-reproducible-training/
└── train.py   # skeleton — implement train()
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/01-reproducible-training
python3 -m venv .venv && . .venv/bin/activate
pip install scikit-learn numpy pytest
```

## Mission

Implement `train()` in `train.py` so that all four conditions hold:

| Requirement | Detail |
|-------------|--------|
| Saves artifact | `model.pkl` written to the work directory via `pickle.dump` |
| Returns metric | A `float` — the test-set accuracy |
| Meets threshold | `accuracy >= THRESHOLD` (0.80) |
| Fully reproducible | Two consecutive `train()` calls produce **identical predictions** on the same probe set |

`make_dataset()` is already seeded — do not modify it. Your job is the split, the model, and the save.

## Why it matters

Three sources of non-determinism bite ML training:

1. **Uncontrolled split**: `train_test_split` without `random_state` shuffles differently on each call — your train/test boundary shifts, your reported metric is a lie.
2. **Uncontrolled model**: tree ensembles, gradient boosters, and some linear solvers have internal randomness gated by `random_state` (or `seed`). Without it, the tree split order and weight initialisation vary per run.
3. **Floating-point thread races**: multi-threaded BLAS can accumulate floats in different orders on different runs. For sklearn, `n_jobs=1` eliminates this.

The production rule: **every RNG-backed call takes an explicit `random_state`**. After each training run, hash the saved artifact — if the SHA changes with identical inputs, you have a hidden non-determinism source to hunt.

## Verify

```bash
bash courses/course-24-mlops/challenges/01-reproducible-training/verify.sh
```

All four tests green → flag printed.
