# Hypothesis Test — Two-Sample t-Test

A product manager asks: *"We ran an A/B test — group A saw the old checkout flow, group B saw the new one. Their completion times (in seconds) are in the CSV. Can you tell me with statistical confidence whether the new flow is actually different?"*

You load the data, look at the means, and notice a 4-second difference. But is it real, or sampling noise? Your job: run the correct hypothesis test and report the p-value and decision.

## Context

`setup.sh` plants the files in your work directory:

```
~/.kube-dojo-work/03-hypothesis-test/
├── samples.csv          # seeded CSV: columns "group_a" and "group_b" — do not modify
├── solution.py          # skeleton with a run_test() stub
└── tests/
    └── test_sample.py   # two visible tests: return-type checks
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/03-hypothesis-test
python3 -m venv .venv && . .venv/bin/activate
pip install pytest numpy pandas scipy
```

## The samples

`samples.csv` has two columns, `group_a` and `group_b`, each with 80 observations sampled from normal distributions with slightly different means. The exact values are seeded and deterministic — `setup.sh` always generates the same CSV.

## Mission

Implement `run_test(a, b)` in `solution.py`:

```
run_test(a: np.ndarray, b: np.ndarray) -> dict
```

Where `a` and `b` are 1-D NumPy arrays of floats.

The function must return a dict with exactly these keys:

| Key | Type | Description |
|---|---|---|
| `"statistic"` | float | the t-statistic from the test |
| `"p_value"` | float | the two-tailed p-value |
| `"reject_null"` | bool | `True` if p_value < 0.05, else `False` |

### Which test to use

You want a **two-sample (independent-samples) t-test**, also called Welch's t-test:
- Two groups, independent observations.
- We do **not** assume equal variances (use `equal_var=False`, which is Welch's — it is safer by default).
- Two-tailed: we want to detect *any* difference in means, not just "is B greater than A".

In SciPy: `scipy.stats.ttest_ind(a, b, equal_var=False)`.

### The null hypothesis

H₀: the population means of group A and group B are equal (μ_A = μ_B).
H₁: they are not equal (two-tailed).
Alpha: 0.05.

**Reject H₀ if p_value < 0.05.** That means the observed difference is unlikely to be explained by chance alone.

## Why this matters for engineers

Statistical testing shows up in SDE work more than most engineers expect:
- **A/B testing** (feature flags, UI changes, pricing experiments).
- **Performance benchmarking** ("is the new algorithm faster, or did we just get lucky with the benchmark runs?").
- **Canary deployments** ("is the error rate on the 5% canary actually higher, or is it noise?").

Knowing when to apply a t-test (continuous, approximately normal, two independent groups) versus a chi-squared test (categorical) versus a Mann-Whitney U (non-normal) is the difference between shipping decisions backed by evidence and shipping decisions backed by vibes.

## Verify

```bash
bash courses/course-21-data-science-python/challenges/03-hypothesis-test/verify.sh
```

The hidden verifier asserts `p_value` within `1e-6` tolerance and the exact boolean `reject_null`. Flag printed on full pass.
