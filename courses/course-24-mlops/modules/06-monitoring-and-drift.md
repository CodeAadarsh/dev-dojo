# Monitoring & Drift

> **Module 06 · Course 24** — A model that shipped clean can silently degrade over months as the world diverges from its training distribution. Unlike a service outage — loud, paged, unambiguous — model decay is quiet: predictions still return 200 OK, latencies look fine, and the only signal is a slow erosion of a business metric nobody looks at until a quarterly review. This module is about detecting that erosion before your users do.

The key mental shift: *a model is not a deployed binary, it's a deployed assumption about the world*. When the world changes, the assumption breaks — even if you never touched the code.

---

## Data drift vs concept drift

These are distinct failure modes. Confusing them leads to wrong interventions.

| | Data drift | Concept drift |
|--|-----------|---------------|
| **What changes** | Input distribution P(X) | The relationship P(Y\|X) |
| **Example** | Users from a new region with different spending patterns start arriving | Inflation changes what "high income" means for churn prediction |
| **Detectable without labels?** | Yes — compare current inputs to training inputs | No — you need observed outcomes |
| **Intervention** | Retrain on current distribution; may also need feature engineering | Retrain; may also need new features or model architecture |
| **Detection latency** | Fast (hours to days, detectable from request stream) | Slow (weeks to months, requires ground truth accumulation) |

In practice, data drift is your **early warning signal** — you can detect it the moment inputs start shifting, long before you have enough labels to measure concept drift. A good monitoring system combines both: drift detection as the trigger, label monitoring as the confirmation.

---

## Measuring data drift

### Population Stability Index (PSI)

PSI is the workhorse for feature drift in production ML. It compares the distribution of a feature in the *reference* (training) population to the *current* (serving) population.

```
        B
PSI = Σ (actual_i% − expected_i%) × ln(actual_i% / expected_i%)
       i=1
```

Where `B` is the number of buckets (typically 10 for numeric, all categories for categorical), `expected_i%` is the fraction of reference data in bucket `i`, and `actual_i%` is the fraction of current data in that bucket.

**Interpreting PSI:**

| PSI range | Interpretation | Action |
|-----------|---------------|--------|
| < 0.1 | No significant drift | No action |
| 0.1 – 0.2 | Moderate drift | Investigate; may retrain soon |
| > 0.2 | High drift | Retrain; monitor closely |

Python implementation without third-party drift libraries:

```python
import numpy as np

def psi(reference: np.ndarray, current: np.ndarray, buckets: int = 10) -> float:
    """Population Stability Index. reference and current are 1-D arrays of values."""
    breakpoints     = np.percentile(reference, np.linspace(0, 100, buckets + 1))
    breakpoints[0]  = -np.inf
    breakpoints[-1] = np.inf

    ref_counts = np.histogram(reference, bins=breakpoints)[0]
    cur_counts = np.histogram(current,   bins=breakpoints)[0]

    # avoid division by zero / log(0)
    ref_pct = np.where(ref_counts == 0, 1e-4, ref_counts / len(reference))
    cur_pct = np.where(cur_counts == 0, 1e-4, cur_counts / len(current))

    return float(np.sum((cur_pct - ref_pct) * np.log(cur_pct / ref_pct)))
```

PSI is symmetric in the sense that large deviations in either direction contribute positively — the product of sign-preserving terms always adds up. A PSI of 0.25 on `feature_age` is a hard retrain signal regardless of which direction age has shifted.

### Kolmogorov-Smirnov (KS) test

The KS statistic measures the maximum absolute difference between the cumulative distribution functions (CDFs) of two samples. Unlike PSI, it comes with a p-value.

```python
from scipy.stats import ks_2samp

stat, p_value = ks_2samp(reference_age, current_age)
# stat:    max CDF distance (0 = identical, 1 = completely non-overlapping)
# p_value < 0.05: distributions are statistically different at 95% confidence
```

KS is better for detecting *sharp* distributional shifts (a single new peak in the distribution). PSI is better for *gradual* shifts across the whole distribution. Use both; they're not redundant.

| Metric | Sensitivity | Best for | Setup required |
|--------|------------|---------|----------------|
| PSI | Gradual overall shift | Numeric features, monitoring dashboards | Bucket definitions from training data |
| KS | Sharp shifts, bimodality | Continuous features, statistical testing | None; raw arrays |
| Chi-squared | Categorical frequency shift | Category distribution monitoring | Contingency table |

---

## Prediction monitoring

Before you have ground-truth labels, you have predictions. Monitor the output distribution — it's free signal that's available immediately.

```
  reference predictions:  mean=0.23, p95=0.71, % predicted positive=18%
  current predictions:    mean=0.41, p95=0.92, % predicted positive=34%
  ── alert: output distribution has shifted significantly ──
```

What to track on the prediction stream:

- **Mean and median score** — a sudden shift often means a feature upstream went null or was incorrectly imputed
- **Score distribution percentiles (p25, p50, p75, p95, p99)** — shape changes catch multimodal distribution shifts
- **Fraction above decision threshold** — directly observable proxy for business impact
- **Prediction confidence** — a well-calibrated model in-distribution has a characteristic confidence histogram; out-of-distribution inputs push predictions toward 0.5 or to extremes depending on architecture

### Label monitoring

Label monitoring is the ground-truth check, but it requires delayed feedback (users churn 30 days after the prediction, fraud is confirmed 7 days later, a clinical outcome takes months). Track:

- **Realized label rate vs predicted positive rate** — if your model predicts 30% churn and only 10% actually churn, you have calibration drift or concept drift
- **Precision@K on recent cohort** — most actionable when your model drives ranked interventions (top-K at-risk users, top-K fraud candidates)
- **Rolling AUC** — window-based AUC as labels arrive; a downward trend over multiple cohorts is concept drift

```python
def monitor_label_cohort(cohort_df, window_days=30):
    """cohort_df: rows with prediction_score and observed label."""
    from sklearn.metrics import roc_auc_score
    if len(cohort_df) < 500:
        return   # too few labels for a statistically meaningful AUC estimate
    auc = roc_auc_score(cohort_df["label"], cohort_df["prediction_score"])
    if auc < ONLINE_AUC_THRESHOLD:
        fire_alert(f"Online AUC {auc:.3f} below threshold {ONLINE_AUC_THRESHOLD}")
```

---

## Performance decay and alerting

Model performance degrades non-linearly. The first few weeks after deployment are usually stable. Then, as the world drifts, precision/recall erodes in steps — a new cohort of users, a season change, a product feature launch that changes behavior patterns.

```
  AUC
  0.88 ┤▓▓▓▓▓▓▓▓▓▓▓
  0.86 ┤           ▓▓▓▓▓▓▓▓▓▓▓▓
  0.84 ┤                       ▓▓▓▓▓▓▓▓
  0.82 ┤                               ▓▓▓▓▓   ← retrain trigger threshold
  0.80 ┤                                   ▓▓▓▓▓  ← alarm: page on-call
       └────────────────────────────────────────── time (weeks)
```

Set two thresholds, not one:

- **Retrain trigger**: PSI > 0.2 OR rolling AUC < 0.84 → fire CT pipeline automatically
- **Alarm threshold**: PSI > 0.35 OR rolling AUC < 0.80 → page on-call; consider temporary fallback to a rule-based system

Alerting on drift metrics with only one threshold leads to alert fatigue. The retrain trigger is automatic and cheap (just kicks off the pipeline). The alarm is reserved for "something is badly wrong right now and the pipeline alone can't fix it fast enough."

---

## Shadow mode and canary for models

Two techniques for validating a new model against live traffic before it affects users.

### Shadow mode

The challenger model receives the same input as the champion but its predictions are *not* served. They're logged and compared offline.

```
  request ──► champion ──► response to user
          │
          └─► challenger ──► prediction logged (not served)
                                   │
                             comparison job (nightly):
                             agreement rate, distribution delta,
                             per-slice disagreement patterns
```

Shadow mode answers: where do champion and challenger disagree, and on which population? A high disagreement rate on a specific segment (new market, mobile users, recently onboarded accounts) is a warning signal before you commit to the switch. It's free signal with zero user impact.

### Canary deployment for models

A fraction of traffic is routed to the challenger. Unlike shadow mode, these predictions *do* affect users — so start small (1%, then 5%, then 10%) and watch online metrics closely.

```yaml
# Istio VirtualService — 5% canary for a model endpoint
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: churn-model
  namespace: dojo-mlops
spec:
  http:
  - match:
    - uri:
        prefix: /predict
    route:
    - destination:
        host: churn-model-champion
        port:
          number: 8080
      weight: 95
    - destination:
        host: churn-model-challenger
        port:
          number: 8080
      weight: 5
```

Decision to promote: challenger online AUC >= champion - 0.002 **and** no latency regression over a 72-hour window. Decision to abort: any degradation in the primary business metric (conversion, retention, revenue per prediction) attributed to the challenger traffic slice.

---

## The feedback loop

Predictions → user behavior → observed labels → retraining data → better predictions. Closing this loop is the difference between a deployed model and an ML *system*.

```
  Model serves prediction
          │
  User acts (or doesn't act)
          │
  Event logged (click, churn, fraud confirmed, outcome recorded)
          │
  Label assigned to (prediction_score, feature_vector) record
          │
  Label monitoring fires if realized rate diverges from predicted rate
          │
  Retrain triggered → new candidate → eval gate → champion swap
```

The latency in this loop is your maximum "drift blindness" — the window between a distribution shift and your ability to detect and respond to it. Reduce it by:

1. Shortening label delay where possible (use proxy labels for early signal — e.g., a 7-day activity proxy before the 30-day churn label arrives)
2. Running data drift checks on raw input, not just outcome metrics — you can act on PSI today, on AUC decay only after labels arrive
3. Keeping the CT pipeline fast enough that a retrain-to-deploy cycle is measured in hours, not days

---

## Debugging Monitoring & Drift

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| PSI normal; business metric is eroding | Concept drift — P(Y\|X) changed; inputs look the same but outputs shouldn't | Need labels; run label cohort analysis; retrain with recent ground truth |
| Drift alert fires but model performance is unchanged | Seasonal or cyclical data pattern (weekly or annual cycle hit the reference window) | Compute PSI against same-period reference from prior year, not the overall training baseline |
| Drift alert fires every Monday | Weekday vs weekend distribution shift; reference uses all days equally | Compute PSI per day-of-week stratum, or use a rolling 7-day reference window |
| Label monitoring shows degradation but retraining doesn't help | Ground-truth labels are delayed or mislabeled; training on stale or corrupted labels | Investigate the label pipeline; use proxy labels or semi-supervised approach until label quality improves |
| Shadow challenger disagrees on 40% of inputs but online AUC looks the same | Models disagree on easy cases, not hard ones; the disagreements are low-stakes | Check disagreement slices by confidence score; if high-confidence disagreements are on low-value inputs, proceed with the canary |
| Monitoring shows no drift; users complain predictions are wrong | Monitoring doesn't cover the right features; upstream schema changed silently | Add monitoring for all high-importance features by training cardinality; add schema assertions to the ingestion path |

> **War story.** On the LGTM log pipeline at SAP, we ran a log-anomaly classifier that flagged unusual pod log patterns. After three months, the false positive rate doubled. PSI on the raw log-volume features was 0.08 — well within the "no action" band. The actual drift was in a *categorical* feature: the distribution of Kubernetes namespace names had shifted as new microservices launched. We weren't monitoring it because we'd hand-labeled it "low importance" during feature selection. A Chi-squared test on namespace distribution would have fired weeks earlier. The lesson: importance rankings from training are a starting point, not a monitoring scope. Add drift checks for at least the top-20 features *by training cardinality*, not only by SHAP value — rare-but-discriminative features are the ones that shift silently and hurt the most.

---

## Checkpoint

You're solid on monitoring and drift when you can, without looking anything up:

1. State the difference between data drift and concept drift in one sentence each, and say which one requires labels to detect.
2. Interpret a PSI score of 0.15 on the `feature_income` column: what action does it call for?
3. Explain why the KS test and PSI are not redundant — what does each catch that the other might miss?
4. Describe three things to monitor on the prediction stream *before* ground-truth labels are available.
5. Define the two threshold levels for drift alerting and explain why there are two rather than one.
6. Explain shadow mode: where do the challenger predictions go, and what question does the overnight comparison job answer?
7. Describe the feedback loop: list the steps from a served prediction to a retrain trigger.
8. Name the most common cause of Monday drift alarms and the correct fix.

➡ Next up: **Scaling & Cost** — keeping GPU costs from eating the budget as the system grows.
