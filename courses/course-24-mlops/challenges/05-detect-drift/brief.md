# Detect Drift

Six weeks after you deployed the Iris classifier, model accuracy starts silently degrading. No exceptions, no 5xx — the service is healthy, but predictions are drifting toward the wrong class. The on-call SRE files a ticket: *"We're getting feature distributions we've never seen at training time. We need a drift detector that can alert before accuracy collapses."*

Your job: implement `drift.py` so the monitoring harness can distinguish stable traffic from shifted traffic.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/05-detect-drift/
├── reference.npy      # baseline distribution — same feature space as training (seeded)
├── no_drift.npy       # production sample that matches the reference (no drift)
├── drifted.npy        # production sample with covariate shift (drift present)
├── drift.py           # skeleton with detect() stub
└── tests/
    └── test_drift.py  # visible sample tests; hidden harness runs at verify time
```

Each `.npy` file is a float64 array of shape `(N, 4)` — one row per sample, four Iris features per row.

## Prerequisites

```bash
cd ~/.kube-dojo-work/05-detect-drift
python3 -m venv .venv && . .venv/bin/activate
pip install scikit-learn pytest numpy scipy pandas
```

## Mission

Implement `detect(reference, current, threshold)` in `drift.py`. The function must:

1. **Compute a drift score** using either:
   - **PSI (Population Stability Index):** bin each feature into 10 equal-width buckets over the reference, compute per-bucket frequency ratios, and sum PSI across all features.
   - **KS statistic:** apply `scipy.stats.ks_2samp` per feature and take the maximum KS statistic.

2. **Return a dict** with exactly these keys:

| Key | Type | Meaning |
|-----|------|---------|
| `score` | `float` | aggregate PSI sum or max KS statistic |
| `drift` | `bool` | `True` if `score >= threshold` |

## Thresholds and tolerance

The verifier uses **`threshold=0.2`** (PSI-style) or **`threshold=0.1`** (KS-style). Both are industry-standard alerting thresholds. The harness also validates that your `score` is **within 15% of the reference implementation's value** — so a wildly wrong binning strategy will fail even if the boolean happens to match.

| Dataset | Expected outcome at threshold |
|---------|-------------------------------|
| `no_drift.npy` | `drift == False` (score well below threshold) |
| `drifted.npy` | `drift == True` (score above threshold) |

## Why drift detection matters before it bites you

PSI is the most widely deployed drift metric in financial ML. A PSI below 0.1 means negligible shift; 0.1–0.2 is moderate (investigate); above 0.2 means the distribution has moved enough to retrain. KS is non-parametric: it's distribution-agnostic and one-tailed, making it useful when you don't know what shift to expect.

The real cost of missing drift: a model trained on Q1 spending patterns serving Q4 holiday traffic produces confidently wrong predictions. No exception is raised. Accuracy decays slowly. By the time a human notices, the damage is weeks old.

## What the verify harness checks

| Check | Pass condition |
|-------|---------------|
| No-drift sample → `drift == False` | score below threshold on stable traffic |
| Drifted sample → `drift == True` | score above threshold on shifted traffic |
| Score accuracy | `abs(score - expected) / expected < 0.15` |
| Return shape | dict with `score` (float) and `drift` (bool) |

## Verify

```bash
bash courses/course-24-mlops/challenges/05-detect-drift/verify.sh
```

All checks green → flag printed.
