# Solution — Hypothesis Test — Two-Sample t-Test

## The complete solution

```python
import numpy as np
from scipy import stats


def run_test(a: np.ndarray, b: np.ndarray) -> dict:
    result = stats.ttest_ind(a, b, equal_var=False)
    return {
        "statistic": float(result.statistic),
        "p_value": float(result.pvalue),
        "reject_null": bool(result.pvalue < 0.05),
    }
```

Four lines. The complexity is all in *knowing which test to pick* and *why*.

## Reasoning through the test choice

### The decision tree

```
Is the outcome variable continuous?
  YES → Is it approximately normal (or n > 30 by CLT)?
    YES → How many groups?
      TWO independent groups → t-test
        Equal variances assumed? → Student's t (rarely safe)
        Unequal variances OK?   → Welch's t  (default choice)
      ONE group vs. known mean  → one-sample t-test
      TWO paired observations   → paired t-test
    NO (ordinal, heavy-tailed)  → Mann-Whitney U
  NO (categorical counts)       → chi-squared test
```

The checkout time problem: continuous outcome (seconds), two independent groups (A and B customers never overlap), roughly normal by CLT (n=80 each). → Two-sample Welch's t-test.

### Why Welch, not Student

Student's t-test assumes the two populations have equal variances (`equal_var=True`). When they don't — and you usually don't know ahead of time — Student's gives inflated Type I error. Welch's t-test uses a modified degrees-of-freedom calculation (the Welch-Satterthwaite equation) that remains valid regardless of whether variances match. The cost is negligible: Welch has very slightly less power when variances truly are equal, but the difference is tiny and the robustness is large. Always use `equal_var=False` unless you have a strong domain reason to believe equal variances.

### Why two-tailed

A one-tailed test (H₁: μ_B < μ_A, "new flow is faster") has more power to detect that specific direction but commits you before looking at the data. Two-tailed (H₁: μ_A ≠ μ_B) is the honest default for an A/B test where you want to know *if* there is a difference, not just whether it's in your hoped-for direction. Pre-registering one-tailed tests to gain power is valid; choosing one-tailed *after* seeing the data to get a lower p-value is p-hacking.

## Interpreting the output

For the seeded data in this challenge (group A: N(50, 8), group B: N(46, 9), n=80 each):

- `t ≈ 2.9` — the difference in means is about 2.9 standard errors away from zero.
- `p ≈ 0.004` — there is about a 0.4% probability of observing a difference this large purely by chance if the null hypothesis were true.
- `reject_null = True` — at alpha=0.05 we reject H₀. The new checkout flow does appear to have a different (lower) mean completion time.

## Common mistakes

**Forgetting `float()` and `bool()` casts** — `result.statistic` is a NumPy scalar (`np.float64`), not a Python `float`. `result.pvalue < 0.05` returns a `np.bool_`, not a Python `bool`. The verifier checks `isinstance(result["reject_null"], bool)`, which fails for `np.bool_`. Always cast.

**Using `equal_var=True` (Student's test)** — the hidden verifier checks the exact statistic against Welch's. The numbers differ. If you get a close but not-matching statistic, this is the cause.

**Checking `result.pvalue < 0.05` inconsistently** — if you store `p_value` and compute `reject_null` separately, there is no bug as long as both use the same threshold. But if you compute `reject_null` from a rounded or truncated `p_value`, you may get an inconsistency the verifier catches.

## When NOT to use a t-test

| Situation | Use instead |
|---|---|
| Outcome is categorical (converted / not converted) | chi-squared or Fisher's exact |
| Groups are paired (same user, before/after) | paired t-test (`stats.ttest_rel`) |
| Data is heavily skewed, small n | Mann-Whitney U (`stats.mannwhitneyu`) |
| More than 2 groups | one-way ANOVA (`stats.f_oneway`) |
| Multiple simultaneous tests | apply Bonferroni or FDR correction |
