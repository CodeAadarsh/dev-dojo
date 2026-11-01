# CI/CD for ML (CT)

> **Module 05 · Course 24** — Software CI/CD is mature: lint, compile, test, ship, done. ML CI/CD has those same steps *plus* a parallel track where the artifact itself (the model) must be evaluated, compared against a champion, and can silently degrade not because the code changed but because the world did. This module covers the machinery that makes that second track reliable.

You already know GitHub Actions and Docker. The question here is what to *test*, when to *retrain*, how to *gate* a new model before it gets anywhere near traffic, and how to *roll back* when the gate fails in production anyway.

---

## Why ML CI/CD is not just "add a training step"

In software CI, a green test suite means the artifact is safe to ship. In ML CI:

- A green unit test suite means the *code* is correct, but says nothing about whether the *model* is any good.
- The training run itself is non-deterministic (random seeds, GPU fp16 rounding) — the "same" code produces slightly different models.
- The artifact has a shelf life: a model trained on January data may be measurably worse by April even if nothing in the codebase changed.
- Rollback is model rollback, not code rollback — you need to version *artifacts*, not just source.

The industry term for the ML-specific extension of CD is **Continuous Training (CT)**. It layers on top of Continuous Delivery:

```
     Code CI ──► model training ──► model evaluation ──► model registry ──► serving
         │                                  │                    │
     (familiar)               (new: offline eval gate)    (new: champion-challenger)
```

---

## The ML testing pyramid

Three layers. Most teams skip layer 1, half skip layer 2, and everyone ships layer 3 too late.

### Layer 1 — Data tests

Run *before* training, on every new dataset slice that enters the pipeline. They catch corrupted ingestion, schema drift, and leakage early — before wasting a GPU-hour on a poisoned dataset.

```python
# pandera-style schema validation
import pandera as pa

schema = pa.DataFrameSchema({
    "feature_age":    pa.Column(float, pa.Check.between(0, 120), nullable=False),
    "feature_income": pa.Column(float, pa.Check.ge(0),           nullable=False),
    "label_churn":    pa.Column(int,   pa.Check.isin([0, 1]),     nullable=False),
})

schema.validate(df)   # raises SchemaError on violation — fail the pipeline here
```

**What to assert:**

- Schema (column names, dtypes) — catches upstream API changes silently
- Range and cardinality — catches runaway values or new categories
- No-leakage check: `label_churn` must not appear in feature columns (rename accidents happen)
- Temporal correctness: training data `timestamp < cutoff`; test data `timestamp >= cutoff`

### Layer 2 — Model tests (offline evaluation)

Run *after* training, on a held-out evaluation set. These are the gates that decide whether the trained artifact graduates from the registry.

```python
# pytest-based eval gate
import joblib
import numpy as np
from sklearn.metrics import roc_auc_score

THRESHOLD_AUC  = 0.82
CHAMPION_PATH  = "models/champion/model.pkl"
CANDIDATE_PATH = "models/candidate/model.pkl"
FEATURES       = ["feature_age", "feature_income", "feature_tenure"]

def test_candidate_beats_threshold(eval_df):
    model = joblib.load(CANDIDATE_PATH)
    auc   = roc_auc_score(eval_df["label"], model.predict_proba(eval_df[FEATURES])[:, 1])
    assert auc >= THRESHOLD_AUC, f"AUC {auc:.4f} below threshold {THRESHOLD_AUC}"

def test_candidate_beats_champion(eval_df):
    champion  = joblib.load(CHAMPION_PATH)
    candidate = joblib.load(CANDIDATE_PATH)
    c_auc = roc_auc_score(eval_df["label"], champion.predict_proba(eval_df[FEATURES])[:, 1])
    n_auc = roc_auc_score(eval_df["label"], candidate.predict_proba(eval_df[FEATURES])[:, 1])
    assert n_auc >= c_auc - 0.005, f"Candidate AUC {n_auc:.4f} regresses champion {c_auc:.4f}"
```

The `-0.005` slack on the champion comparison matters: a perfect gate demanding strict improvement would create false negatives because random seed variance across training runs is typically ±0.002–0.003. A hard `n_auc > c_auc` would block legitimate retrain cycles whenever the random seed happened to produce a marginally lower result.

### Layer 3 — Behavioral tests (invariance + directional)

These test model *behavior*, not just aggregate metrics. A model can have excellent AUC and still be dangerously wrong in predictable ways.

| Test type | What it checks | Example |
|-----------|---------------|---------|
| **Invariance** | Output doesn't change when irrelevant features change | Swapping `user_id` shouldn't change `churn_probability` |
| **Directional** | Output moves in the expected direction | `income` ↑ → `churn_probability` ↓ (must hold) |
| **Minimum functionality** | Trivially obvious cases are right | A user who cancelled yesterday has `churn=1` |
| **Fairness slice** | No demographic slice is statistically worse | AUC gap between groups < 0.05 |

```python
def test_user_id_invariance(model, reference_row):
    base   = model.predict_proba(reference_row)[0, 1]
    mutant = reference_row.copy()
    mutant["user_id"] = reference_row["user_id"] + 999999
    assert abs(model.predict_proba(mutant)[0, 1] - base) < 1e-6

def test_income_directional(model, reference_row):
    low  = reference_row.copy(); low["feature_income"]  = 20_000
    high = reference_row.copy(); high["feature_income"] = 200_000
    p_low  = model.predict_proba(low)[0, 1]
    p_high = model.predict_proba(high)[0, 1]
    assert p_high < p_low, "Higher income should lower churn probability"
```

Behavioral tests are cheap to write and catch model logic bugs that aggregate metrics obscure. Add them to your training eval suite before adding another metric dashboard.

---

## Continuous Training pipeline architecture

A CT pipeline is triggered → trains → evaluates → gates → promotes or discards.

```
  Trigger ──► Fetch data ──► Feature engineering ──► Train ──► Offline eval ──► Gate?
  (schedule,               (schema-validated,       (fixed     (AUC, behavioral    │
   drift alert,             no leakage)              seed)      tests)         Yes / No
   perf decay)                                                                   │
                                                              ┌──────────────────┴──────────────────┐
                                                              │                                     │
                                                         Promote to                           Discard +
                                                       champion registry                    alert on-call
                                                              │
                                                   Shadow / canary rollout
                                                              │
                                                    Swap serving endpoint
```

### Triggers

Three legitimate reasons to kick off a retrain:

| Trigger | When | Signal source |
|---------|------|---------------|
| **Schedule** | Weekly or monthly cadence | Cron job / Airflow schedule |
| **Data drift** | Input distribution has shifted beyond threshold | PSI > 0.2 on a key feature (Module 06) |
| **Performance decay** | Online metric falls below SLO | Monitoring alert → pipeline trigger |

Avoid schedule-only triggers in production: they guarantee retraining on a cadence, not in response to reality. The best setups use schedule as a *floor* (retrain at least once a month regardless) and drift/perf as *interrupt* triggers.

### GitHub Actions skeleton for a CT pipeline

```yaml
# .github/workflows/ct.yml
name: Continuous Training

on:
  schedule:
    - cron: "0 2 * * 0"   # every Sunday 02:00 UTC
  workflow_dispatch:       # manual trigger; drift/perf alerts call gh workflow run
    inputs:
      trigger_reason:
        description: "drift | perf | manual"
        required: true
        default: "manual"

jobs:
  train-and-gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"

      - name: Install deps
        run: pip install scikit-learn pandas pandera pytest joblib

      - name: Validate training data
        run: python3 -I pipelines/validate_data.py --split train

      - name: Train candidate
        run: python3 -I pipelines/train.py --seed 42 --output models/candidate/

      - name: Offline eval gate
        run: pytest pipelines/tests/test_offline_eval.py -v
        # fails the pipeline if AUC < threshold or candidate regresses champion

      - name: Promote to registry
        if: success()
        run: python3 -I pipelines/promote.py --artifact models/candidate/
```

Key decisions in this skeleton:

- `--seed 42` on the training step: reproducible runs mean the eval gate tests the same model every time for the same dataset. A non-deterministic training step makes eval gate failures ambiguous.
- `python3 -I` for all pipeline scripts: the `-I` flag disables loading packages from the current directory, so a planted `sklearn.py` in the working directory can't shadow the real package.
- Promoting only on `if: success()`: a partial pipeline that fails mid-way and then promotes is strictly worse than a hard stop.

---

## Automated eval gates and champion-challenger

The eval gate is the `if/else` at the top of `promote.py`. It answers: is this candidate meaningfully better than (or at least as good as) what's currently serving?

```
                        ┌──────────────────────────┐
  candidate model ────► │  Eval gate               │
                        │  • AUC ≥ threshold       │ ──► PASS ──► promote to "challenger"
  champion model  ────► │  • AUC ≥ champion - ε    │
                        │  • behavioral suite green │ ──► FAIL ──► discard + alert
                        └──────────────────────────┘
```

**Champion-challenger pattern.** Once a candidate passes the offline gate it becomes the *challenger*. In production it receives a small slice of traffic (5–10%) while the champion handles the rest. Online metrics (click rate, conversion, error rate) are compared over a defined window. If the challenger wins, it becomes the new champion and traffic shifts fully.

```
  100% → champion
    ↓  (challenger promoted from registry)
   90% → champion  |  10% → challenger
    ↓  (challenger wins online metrics window)
  100% → (new) champion     (old champion archived in registry)
```

This is operationally a weighted traffic split — in Kubernetes this is an Istio `VirtualService` weight or an Nginx upstream weight. The ML layer just instructs the serving infrastructure to adjust weights.

---

## Rollback

Model rollback is different from code rollback. The code didn't change — the artifact did.

Rollback decision tree:

1. **Online metric alert fires** (latency spike, error rate, AUC decay) → immediately shift 100% traffic back to the previous champion.
2. **Root cause**: was it the model, the feature pipeline, or serving infrastructure? Do not retrain until you know which.
3. **If model**: the previous champion is in the registry. Redeploy it. No code PR needed.
4. **If feature pipeline**: fix the upstream data issue, then retrain.
5. **Post-mortem**: why did the offline eval gate not catch this? Add a behavioral test or tighten the threshold.

```bash
# restore the previous champion from a model registry (MLflow example)
mlflow models serve \
  -m "models:/churn-model/Production@champion-v12" \
  -p 8080
```

The registry is your time machine. Without artifact versioning, rollback means "find the git SHA and retrain," which takes hours. Every model that ever touched production traffic should be in the registry with enough metadata to redeploy it from a standing start.

---

## Debugging CI/CD for ML

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Bad model ships — metrics drop online despite green offline gate | Eval set is stale (no temporal split, or eval period overlaps training data) | Enforce strict temporal split; eval set must be strictly after training cutoff |
| Behavioral tests pass but model ignores a key feature | Feature leakage in training (a post-event or target-correlated feature included) | Add no-leakage assertion in data tests; check feature importances from the trained model |
| Flaky data tests — same dataset, different pass/fail across runs | Non-deterministic upstream aggregation (shuffle order, float precision) | Fix seed in all shuffle steps; assert row counts before comparing float summaries |
| Retrain loop — pipeline triggers → trains → fails gate → triggers again | Drift trigger threshold too sensitive; model genuinely cannot improve on the drifted distribution | Add a minimum interval between retrain runs; distinguish "data changed" from "learnable" |
| Gate passes in CI but model is worse in shadow traffic | Eval set doesn't match serving distribution (different preprocessing path) | Shadow-compare predictions between eval set and live sample; add serving distribution assertions |

> **War story.** At SAP, we had a usage-prediction model that shipped cleanly through the eval gate for three successive retrain cycles. The fourth retrain caused a 12% drop in precision — caught in shadow mode, never in production. The root cause: a new upstream pipeline had started silently dropping rows with `null` feature values before they reached our training pipeline. Our training data looked clean; our eval set was a pre-filtered slice. In production, nulls still arrived. The model had never seen them in training; it predicted confidently and wrongly. The fix was a behavioral test: inject a row with a null feature value, assert the model returns the expected fallback (our feature engineering had a fill strategy — it just wasn't exercised in eval). The lesson: your eval pipeline must be *byte-for-byte identical* to your serving pipeline. Any preprocessing step that exists in serving and not in eval is a bug waiting for a null.

---

## Checkpoint

You're solid on ML CI/CD when you can, without looking anything up:

1. Explain the difference between a model test and a behavioral test, and give one example of a behavioral test you'd add to a churn model.
2. Name three triggers for a CT pipeline and state which should be the *floor* trigger (minimum cadence), not the interrupt.
3. Sketch the champion-challenger pattern: what decides when traffic shifts, and what percentage starts as challenger?
4. Explain why `--seed 42` on the training step matters for the eval gate to be meaningful.
5. Describe what "eval set is stale" means and how a temporal split prevents it.
6. State the rollback procedure: which resource do you redeploy, and what do you investigate before retraining?
7. Explain what a retrain loop is and the two-part fix (rate-limit + root cause).

➡ Next up: **Monitoring & Drift** — once the model is live, how do you know when the world has moved on.
