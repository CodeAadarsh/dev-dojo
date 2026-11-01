# Solution — Measure Percentiles

```python
from typing import List


def compute_percentile(data: List[float], p: float) -> float:
    if not data:
        raise ValueError("Cannot compute percentile of an empty dataset")
    if p < 0 or p > 100:
        raise ValueError(f"Percentile p must be in [0, 100], got {p}")
    sorted_data = sorted(data)
    n = len(sorted_data)
    if n == 1:
        return float(sorted_data[0])
    rank = p / 100.0 * (n - 1)
    lower = int(rank)
    upper = min(lower + 1, n - 1)
    frac = rank - lower
    return sorted_data[lower] + frac * (sorted_data[upper] - sorted_data[lower])


def check_slo(latencies: List[float], p99_threshold_ms: float) -> bool:
    return compute_percentile(latencies, 99) > p99_threshold_ms
```

Apply and verify:

```bash
cd ~/.kube-dojo-work/02-measure-percentiles
.venv/bin/pytest tests/ -v
bash courses/course-29-performance-engineering/challenges/02-measure-percentiles/verify.sh
```

## Why each piece is required

**`sorted(data)`** — the formula indexes into a sorted array. Forgetting to sort is the second most common percentile bug (after using the wrong formula). Sorting a copy with `sorted()` avoids mutating the caller's list.

**`rank = p / 100 * (n - 1)`** — this is the "inclusive" or "linear" method. It maps p=0 to index 0 and p=100 to index n-1, which are the minimum and maximum respectively. The alternative `rank = p / 100 * n` (exclusive) overshoots p=100 past the last element, requiring a clamp — more error-prone.

**`lower = int(rank)`, `upper = min(lower + 1, n - 1)`** — `int()` truncates toward zero, which is correct for a non-negative rank. The `min` clamp handles p=100 exactly: rank = n-1 is an integer, lower = upper = n-1, frac = 0, result = `sorted_data[n-1]`. Without the clamp, `upper = n` would be an IndexError.

**`frac = rank - lower`** — the fractional part drives the interpolation. When rank lands exactly on an integer (p=0, p=50 on an odd n, etc.), frac = 0 and the result is exactly `sorted_data[lower]`. This is correct.

**`check_slo` uses `>`** (strict). An SLO of "p99 ≤ 200 ms" is _met_ at exactly 200 ms. Returning `True` (breach) for equality would fire false alerts at the boundary.

## The nearest-rank mistake and why it matters in production

The naive nearest-rank formula:

```python
def bad_percentile(data, p):
    sorted_data = sorted(data)
    idx = int(math.ceil(p / 100 * len(sorted_data))) - 1
    return sorted_data[max(idx, 0)]
```

On 10 samples, this maps p95 to `ceil(0.95 * 10) - 1 = 9 - 1 = 8`, i.e. index 8 = the 9th element. The linear-interpolation formula maps p95 to rank 8.55, which interpolates between the 9th and 10th elements. The difference grows when the tail is heavy — the nearest-rank implementation reads optimistically (rounds down), making your p99 look better than it is.

At SAP, a misreported p99 delayed an SLO incident escalation by 45 minutes because the dashboard showed "979 ms" while the corrected calculation was 1 012 ms — 12 ms over the budget. The dashboard fix was exactly this interpolation switch.

## numpy equivalent

```python
import numpy as np
np.percentile(data, 99, interpolation='linear')   # numpy < 1.22
np.percentile(data, 99, method='linear')           # numpy >= 1.22
```

This challenge makes you implement what numpy does under the hood, so you understand the formula when you need to port it to a language without numpy, write it in a SQL window function, or explain a p99 value in an incident review.
