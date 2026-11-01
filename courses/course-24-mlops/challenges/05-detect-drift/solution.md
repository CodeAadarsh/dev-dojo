# Solution — Detect Drift

Two complete implementations of `detect()`. Both pass the verifier.

---

## Approach A — Population Stability Index (PSI)

PSI is the industry standard in credit/risk ML. A PSI > 0.2 means the distribution has shifted enough to require retraining.

```python
import numpy as np


def detect(reference: np.ndarray, current: np.ndarray, threshold: float = 0.2) -> dict:
    n_features = reference.shape[1]
    bins = 10
    total_psi = 0.0

    for i in range(n_features):
        lo    = min(reference[:, i].min(), current[:, i].min())
        hi    = max(reference[:, i].max(), current[:, i].max())
        edges = np.linspace(lo, hi, bins + 1)

        p_ref = np.histogram(reference[:, i], bins=edges)[0] / len(reference)
        p_cur = np.histogram(current[:, i],   bins=edges)[0] / len(current)

        # Replace zeros to avoid log(0) — industry convention: epsilon = 0.0001
        p_ref = np.where(p_ref == 0, 1e-4, p_ref)
        p_cur = np.where(p_cur == 0, 1e-4, p_cur)

        psi_i = float(np.sum((p_cur - p_ref) * np.log(p_cur / p_ref)))
        total_psi += psi_i

    return {"score": total_psi, "drift": total_psi >= threshold}
```

**PSI formula per feature:**

```
PSI_i = Σ (p_current_j - p_reference_j) × ln(p_current_j / p_reference_j)
```

Summed across all bins `j`. The PSI for the whole feature vector is then `Σ PSI_i` across all features.

---

## Approach B — Kolmogorov-Smirnov (KS) statistic

KS is distribution-agnostic: it measures the maximum absolute difference between the empirical CDFs of two samples. It's popular in ML monitoring because it makes no assumptions about the underlying distribution.

```python
import numpy as np
from scipy.stats import ks_2samp


def detect(reference: np.ndarray, current: np.ndarray, threshold: float = 0.1) -> dict:
    n_features = reference.shape[1]
    ks_scores  = [
        ks_2samp(reference[:, i], current[:, i]).statistic
        for i in range(n_features)
    ]
    score = float(max(ks_scores))
    return {"score": score, "drift": score >= threshold}
```

Use `threshold=0.1` with KS; `threshold=0.2` with PSI. The verifier accepts both.

---

## Why per-feature aggregation

A single scalar score hides which feature drifted. In production, log both the aggregate and per-feature scores so you can tell the model team *which* input distribution has shifted — feature 2 (petal length) drifting in Iris maps to "the flower mix at your new supplier is different," which is an actionable finding.

## Apply and verify

```bash
cd ~/.kube-dojo-work/05-detect-drift
# Replace drift.py with either solution above, then:
.venv/bin/pytest tests/ -v
bash courses/course-24-mlops/challenges/05-detect-drift/verify.sh
```
