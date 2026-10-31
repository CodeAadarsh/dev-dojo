# Statistics & Probability for DS

> **Module 04 · Course 21** — Most "data science" mistakes are not coding bugs — they are statistical errors that produce confident-looking numbers with no valid meaning. A p-value of 0.04 that is the result of testing 30 hypotheses is noise. A confidence interval that assumes normality on a right-skewed revenue metric is wrong. An A/B test stopped the moment the result turns significant is p-hacking. This module gives you the statistical grounding to avoid those mistakes and to spot them in other people's work.

Pitched at intermediate: you have seen normal distributions and p-values before. The goal is not memorizing formulas — it is understanding what the assumptions actually are, what breaks when they are violated, and how to make statistically defensible decisions under uncertainty.

---

## Probability distributions — the toolkit

A distribution describes the probability of outcomes for a random variable. In practice, you need to recognize distributions from data and know which statistical tools apply to each.

### Continuous distributions

**Normal (Gaussian)** — `N(μ, σ²)`

```
         μ
         │
    ▓▓▓▓▓│▓▓▓▓▓
   ▓▓▓▓▓▓│▓▓▓▓▓▓
  ▓▓▓▓▓▓▓│▓▓▓▓▓▓▓
 ▓▓▓▓▓▓▓▓│▓▓▓▓▓▓▓▓
─────────────────────
  μ-3σ  μ-σ  μ+σ  μ+3σ

68% of mass within ±1σ
95% within ±2σ
99.7% within ±3σ
```

```python
from scipy import stats
import numpy as np

dist = stats.norm(loc=100, scale=15)   # N(100, 15²)
dist.pdf(100)       # probability density at x=100
dist.cdf(115)       # P(X <= 115) = 0.8413
dist.ppf(0.95)      # 95th percentile = 124.67
dist.rvs(size=1000) # 1000 random samples
```

Appears naturally as the limiting distribution of sums of independent random variables (CLT). Most hypothesis tests assume the *statistic* (not necessarily the raw data) is normally distributed.

**Student's t** — heavier tails than normal, parameterized by degrees of freedom ν.

```python
t_dist = stats.t(df=30)    # degrees of freedom = 30; approaches normal as df → ∞
```

Used for small samples (n < 30) or when population variance is unknown (which is always).

**Uniform** — all outcomes equally likely between [a, b]. Appears in random number generation and as a prior in Bayesian statistics.

**Exponential** — time between events in a Poisson process. Latency distributions often have an exponential tail; inter-arrival times in queuing theory follow exponential.

**Log-normal** — if `log(X)` is normally distributed, then `X` is log-normal. Revenue, page load times, and user session durations are typically log-normal (always positive, right-skewed).

```python
# Fit a log-normal to revenue data
log_rev = np.log(df['revenue'].dropna())
mu, sigma = log_rev.mean(), log_rev.std()
# or:
shape, loc, scale = stats.lognorm.fit(df['revenue'].dropna(), floc=0)
```

### Discrete distributions

**Bernoulli** — a single binary outcome (conversion: yes/no). Parameter `p` = probability of success.

**Binomial** — number of successes in `n` independent Bernoulli trials. Models: how many out of 1000 visitors converted?

```python
from scipy.stats import binom
n, p = 1000, 0.05      # 1000 visitors, 5% baseline conversion rate
binom.pmf(k=60, n=n, p=p)     # P(exactly 60 conversions)
binom.cdf(k=60, n=n, p=p)     # P(at most 60 conversions)
binom.ppf(0.95, n=n, p=p)     # 95th percentile of conversion count
```

**Poisson** — number of events in a fixed interval when events arrive at a constant rate λ. Models: errors per request, support tickets per day, log events per minute.

```python
from scipy.stats import poisson
lam = 5   # average 5 events per minute
poisson.pmf(k=7, mu=lam)   # P(exactly 7 events in one minute)
```

**Knowing the distribution shapes your analysis:**

| observation | likely distribution | consequence |
|-------------|---------------------|-------------|
| revenue, latency | log-normal | log-transform before t-test |
| conversion rates | binomial/beta | use proportion test, not t-test |
| error counts, event rates | Poisson | use Poisson test or chi-square |
| any feature after large aggregation | approx. normal (CLT) | can use z/t-tests on group means |

---

## Sampling and the Central Limit Theorem

### The CLT — the statistical bedrock

**Statement:** Given a population with any distribution with finite mean μ and finite variance σ², the sampling distribution of the sample mean `X̄` of samples of size n converges to `N(μ, σ²/n)` as n → ∞.

In plain terms: even if the population is skewed, exponential, bimodal, or anything else, the *average of a large sample* will be approximately normal. This is why t-tests work on non-normal data for large enough n.

```python
import numpy as np
from scipy import stats

# Demonstrate CLT with a right-skewed population (Exponential)
population = np.random.exponential(scale=10, size=100_000)

sample_means = []
n_per_sample = 30
for _ in range(10_000):
    sample = np.random.choice(population, size=n_per_sample)
    sample_means.append(sample.mean())

sample_means = np.array(sample_means)

# The distribution of sample_means is approximately normal
print(f"Mean of sample means: {sample_means.mean():.2f}  (population mean: {population.mean():.2f})")
print(f"Std of sample means:  {sample_means.std():.2f}  (σ/√n = {population.std()/np.sqrt(n_per_sample):.2f})")

# Normality test on the sampling distribution (not on the population)
stat, p = stats.shapiro(sample_means[:100])   # Shapiro-Wilk on a small subset
print(f"Shapiro-Wilk p={p:.3f}  (> 0.05 → can't reject normality)")
```

**"Large enough n"** is rule-of-thumb 30 for moderately skewed distributions. For heavily skewed distributions (like revenue or latency with extreme outliers), you may need n > 100 or n > 1000 for the CLT to kick in.

### Sampling bias

The CLT applies to *random* samples. A sample that is not random can have any distribution of sample means, regardless of n. Sources of bias:

- **Survivorship bias:** only users who converted are in the dataset.
- **Temporal selection:** you sampled weekday data and are drawing conclusions about all days.
- **Self-selection:** users who opted in to a feature are inherently different from users who didn't.
- **Truncated samples:** you only have data for users active in the last 30 days.

No statistical test can correct for a biased sample.

---

## Point estimates and confidence intervals

A **point estimate** is a single value computed from a sample to estimate a population parameter.

| estimator | estimates |
|-----------|-----------|
| sample mean `X̄` | population mean μ |
| sample proportion `p̂` | population proportion p |
| sample std `s` | population std σ |

A point estimate without a measure of uncertainty is nearly useless for decision-making.

### Confidence intervals

A 95% confidence interval (CI) for the mean:

```
CI = X̄  ±  t_(α/2, n-1) × (s / √n)

where:
  X̄          = sample mean
  s           = sample standard deviation
  n           = sample size
  t_(α/2,n-1) = critical value from t-distribution at significance level α, df=n-1
```

```python
from scipy import stats
import numpy as np

sample = np.array([102, 98, 110, 95, 105, 112, 99, 103])
n = len(sample)

mean = sample.mean()
se = sample.std(ddof=1) / np.sqrt(n)   # standard error; ddof=1 for unbiased std

# 95% CI
alpha = 0.05
t_crit = stats.t.ppf(1 - alpha / 2, df=n - 1)
ci_lo, ci_hi = mean - t_crit * se, mean + t_crit * se
print(f"Mean: {mean:.2f}  95% CI: [{ci_lo:.2f}, {ci_hi:.2f}]")

# Or: stats.t.interval computes it directly
ci = stats.t.interval(confidence=0.95, df=n-1, loc=mean, scale=se)
```

**What a 95% CI means (and does not mean):**

It means: if we repeated this sampling procedure many times, 95% of the CIs we construct would contain the true population mean.

It does *not* mean: "there is a 95% probability that the true mean is in this interval." The true mean is either in the interval or it is not — probability does not apply to a fixed value. (This is the frequentist vs Bayesian distinction; the Bayesian credible interval does give the posterior probability statement.)

**Width of CI:** wider CI = more uncertainty. To halve the CI width, you need 4× the sample size (because CI ∝ 1/√n).

---

## Hypothesis testing — the framework

Hypothesis testing is a decision procedure, not a truth-finding procedure. It answers: "Is this sample result surprising enough to act on?"

**The five steps:**

1. **Null hypothesis H₀:** the "nothing happened" model (e.g., "the two means are equal").
2. **Alternative hypothesis H₁:** what we'd conclude if we reject H₀.
3. **Test statistic:** a number computed from the data that measures how far the data is from H₀.
4. **p-value:** the probability of observing a test statistic as extreme as this (or more), *assuming H₀ is true*.
5. **Decision:** if p < α (significance level, usually 0.05), reject H₀.

### The t-test

Tests whether the mean of a sample differs from a reference value (one-sample) or whether two sample means are equal (two-sample).

```python
from scipy import stats

# One-sample: is the mean conversion rate different from 5%?
conversions = np.array([6.1, 5.8, 6.3, 5.5, 6.0, 6.2, 5.9, 6.1])
stat, p = stats.ttest_1samp(conversions, popmean=5.0)
print(f"t={stat:.3f}, p={p:.4f}")

# Two-sample (independent): do groups A and B have different means?
control = np.random.normal(loc=100, scale=15, size=150)
treatment = np.random.normal(loc=105, scale=15, size=150)
stat, p = stats.ttest_ind(control, treatment, equal_var=False)  # Welch's t-test
print(f"t={stat:.3f}, p={p:.4f}")

# Paired t-test: same users before and after
before = np.array([82, 91, 95, 88, 72, 78, 90, 92])
after  = np.array([88, 93, 99, 90, 79, 81, 94, 96])
stat, p = stats.ttest_rel(before, after)
print(f"t={stat:.3f}, p={p:.4f}")
```

**Assumptions of the t-test:**
- Independent observations (or paired, for the paired version)
- Approximately normally distributed data *or* large n (CLT)
- For two-sample: equal variance (use Welch's `equal_var=False` to relax this — Welch's t-test is almost always the right choice)

### Chi-square test

Tests for independence between two categorical variables, or goodness of fit between observed and expected frequencies.

```python
from scipy.stats import chi2_contingency, chi2

# Test: is conversion rate independent of region?
observed = np.array([[150, 850],   # IN: 150 converted, 850 did not
                     [200, 800],   # SG
                     [80,  920]])  # US

chi2_stat, p, dof, expected = chi2_contingency(observed)
print(f"chi2={chi2_stat:.2f}, p={p:.4f}, df={dof}")
# if p < 0.05: conversion rate is NOT independent of region

# Goodness of fit: are dice rolls uniformly distributed?
observed_rolls = np.array([18, 22, 19, 21, 20, 20])
expected_rolls = np.array([20, 20, 20, 20, 20, 20])   # uniform
chi2_stat, p = stats.chisquare(observed_rolls, expected_rolls)
```

**Assumptions:**
- Expected frequencies ≥ 5 in each cell (rule of thumb). If violated, use Fisher's exact test.
- Observations are independent.

### Mann-Whitney U test (non-parametric)

Use this instead of t-test when n is small, the distribution is strongly non-normal, or you are comparing medians.

```python
stat, p = stats.mannwhitneyu(control, treatment, alternative='two-sided')
```

The Mann-Whitney U tests whether one distribution is stochastically greater than the other — it does not require normality.

---

## p-values — what they are and their misuse

The p-value is one of the most misunderstood concepts in applied statistics.

**What p=0.03 means:**

> If H₀ were true (no real difference), there is a 3% chance of observing data at least this extreme by chance alone.

**What p=0.03 does NOT mean:**
- There is a 97% probability that H₁ is true.
- The effect is large or practically meaningful.
- The result will replicate.
- The hypothesis was tested only once (if you checked the p-value 20 times during data collection and stopped when it was significant, the real false positive rate is much higher than 5%).

**The α threshold (0.05) is arbitrary.** It comes from R.A. Fisher suggesting it as a rough guideline in 1925. Using it as a binary "significant/not significant" switch discards information.

---

## Effect size

A p-value tells you about the evidence. Effect size tells you about the *magnitude* of the difference. Both are necessary.

**Cohen's d** — standardized mean difference:

```
d = (μ₁ - μ₂) / s_pooled

where s_pooled = sqrt((s₁² + s₂²) / 2)

d ≈ 0.2: small effect
d ≈ 0.5: medium effect
d ≈ 0.8: large effect
```

```python
def cohens_d(group1, group2):
    n1, n2 = len(group1), len(group2)
    var1, var2 = np.var(group1, ddof=1), np.var(group2, ddof=1)
    pooled_std = np.sqrt(((n1 - 1) * var1 + (n2 - 1) * var2) / (n1 + n2 - 2))
    return (np.mean(group1) - np.mean(group2)) / pooled_std

d = cohens_d(control, treatment)
print(f"Cohen's d = {d:.3f}")
```

**Practical significance vs statistical significance:**

With 1 million users in an A/B test, a difference of 0.001% in conversion rate will be statistically significant (p < 0.001) but has zero business impact. Always compute effect size alongside p-value. The question is not "is this real?" (large n answers that trivially) — it is "is this large enough to matter?"

**For proportions:** use relative lift and 95% CI on the difference, not just p-value.

```python
n_control, conv_control = 5000, 250     # 5% conversion
n_treat,   conv_treat   = 5000, 300     # 6% conversion

lift = (conv_treat/n_treat - conv_control/n_control) / (conv_control/n_control)
print(f"Relative lift: {lift:.1%}")    # 20% relative lift

# CI on the difference in proportions
p1 = conv_control / n_control
p2 = conv_treat / n_treat
se = np.sqrt(p1*(1-p1)/n_control + p2*(1-p2)/n_treat)
diff = p2 - p1
ci = diff + np.array([-1, 1]) * 1.96 * se
print(f"Absolute diff: {diff:.3f}  95% CI: {ci}")
```

---

## A/B testing fundamentals

A/B testing is a controlled experiment: split users randomly into a control group (A) and treatment group (B), apply the change to B, measure the outcome metric.

### Design before running

**1. Define the primary metric and a success criterion upfront.** Changing the metric after seeing the result is p-hacking.

**2. Compute the required sample size:**

```python
from statsmodels.stats.power import tt_ind_solve_power
from statsmodels.stats.proportion import proportion_effectsize

# For a proportion test (conversion rate)
baseline = 0.05    # 5% baseline conversion
min_detectable_effect = 0.01   # want to detect a 1pp absolute lift (20% relative)
target = baseline + min_detectable_effect

effect_size = proportion_effectsize(baseline, target)   # Cohen's h
n_per_group = tt_ind_solve_power(
    effect_size=effect_size,
    alpha=0.05,            # Type I error rate
    power=0.80,            # 1 - Type II error rate
    ratio=1,               # equal group sizes
    alternative='two-sided'
)
print(f"Required n per group: {n_per_group:.0f}")
```

**3. Run until the predetermined sample size is reached.** Do not stop early.

**4. Check the result once.** Multiple checks require multiple-testing correction.

### Type I and Type II errors

```
                    H₀ true          H₀ false (real effect)
                 ┌──────────────────┬──────────────────────┐
reject H₀ (p<α) │  Type I error    │      Correct         │
                 │  False positive  │  (True positive)     │
                 │  rate = α        │  rate = power (1-β)  │
                 ├──────────────────┼──────────────────────┤
fail to reject   │  Correct         │  Type II error       │
                 │  (True negative) │  False negative      │
                 │  rate = 1-α      │  rate = β            │
                 └──────────────────┴──────────────────────┘
```

- **α** (significance level) = maximum tolerable Type I error rate. 0.05 means a 5% chance of declaring a winner when there is none.
- **β** = Type II error rate. `power = 1 - β` = probability of detecting a real effect. Standard power = 0.80 means 20% chance of missing a real effect.
- **The tradeoff:** lower α reduces false positives but requires more sample to maintain power.

### Guardrail metrics

Always define guardrail metrics — metrics that must not degrade. A treatment that improves conversion but increases latency by 200ms may be a net negative. Run guardrail checks after the primary analysis, but guard against the multiple-testing problem.

---

## Correlation vs causation — a precise statement

Correlation measures linear association between two variables. It is a symmetric, dimensionless number between −1 and +1 and makes no claim about direction.

**Three mechanisms that produce correlation without causation:**

```
1. Reverse causality        2. Confounding              3. Spurious
                               (common cause)
   Revenue → Ad spend          Product launch               Ice cream → Drowning
   (high revenue enables        │                            (both caused by summer)
    higher ad budgets)          ▼                            ┌────────────────┐
                          ┌────────────────┐                │ Hot weather    │
   You observe            │  Ad spend      │                │ causes both    │
   ad_spend → revenue     │  Revenue       │                └────────────────┘
   because you look        └────────────────┘
   forward in time         both rise together
```

The observational data cannot distinguish these three cases. You need:
- A randomized controlled experiment (RCT) — random assignment breaks confounding
- A natural experiment or instrumental variable — when RCT is impossible
- Difference-in-differences — compares changes across treatment/control groups over time

---

## Debugging statistics

### p-hacking

**Stopping early** — checking the p-value while collecting data and stopping when p < 0.05. If you check every day for 20 days, the Type I error rate is not 5% — it is closer to 30%.

Fix: use a sequential testing method (e.g., Sequential Probability Ratio Test) or a Bayesian approach if you need early stopping. Otherwise, commit to a sample size and check once.

**Hypothesis fishing** — trying 20 different metrics and reporting the one with p < 0.05.

Fix: preregister the analysis plan. State the primary metric, sample size, and decision rule before looking at the data.

**Selective reporting** — running the same test on different subgroups until one is significant.

Fix: treat subgroup analyses as exploratory, not confirmatory. Require replication.

### Multiple comparisons

Every test you run at α=0.05 has a 5% false positive rate. If you run 20 independent tests, the probability of at least one false positive is:

```
1 - (1 - 0.05)²⁰ = 0.64   — 64% chance of at least one false alarm
```

**Bonferroni correction** — divide α by the number of tests:

```python
alpha = 0.05
n_tests = 20
alpha_corrected = alpha / n_tests   # 0.0025

# Apply: only declare significant if p < 0.0025
```

Bonferroni is conservative (reduces power). For correlated tests, use Benjamini-Hochberg (controls the False Discovery Rate):

```python
from statsmodels.stats.multitest import multipletests

pvalues = [0.01, 0.04, 0.03, 0.25, 0.001, 0.08]
reject, pvals_corrected, _, _ = multipletests(pvalues, alpha=0.05, method='fdr_bh')
# reject is an array of booleans — True where H₀ can be rejected after FDR correction
```

### Assumption violations

**t-test on a very non-normal, small-n sample:**

```python
# Check normality before applying t-test on small samples
from scipy.stats import shapiro, normaltest

stat, p = shapiro(sample)    # Shapiro-Wilk — best for n < 50
print(f"Shapiro-Wilk p={p:.4f}")
# p < 0.05: reject normality → use Mann-Whitney U instead

stat, p = normaltest(sample)  # D'Agostino-Pearson — better for n > 50
```

**Unequal variances in two-sample t-test:**

```python
# Levene's test for equality of variances
stat, p = stats.levene(group1, group2)
# p < 0.05: variances are significantly different → use equal_var=False (Welch's)

# In practice: always use Welch's. It performs equally well when variances are equal
# and better when they are not. There is no reason to use Student's t-test.
```

**Dependent observations in a t-test:**

If data points are not independent (e.g., the same user appears multiple times), the t-test standard error is wrong — it will be too small, inflating the t-statistic and producing false positives. Fix: use paired t-test, aggregate to user level first, or use a mixed-effects model.

**Chi-square with expected < 5:**

```python
chi2_stat, p, dof, expected = chi2_contingency(observed)
if (expected < 5).any():
    print("Warning: some expected frequencies < 5 — chi-square may be unreliable")
    # use Fisher's exact test instead
    from scipy.stats import fisher_exact
    stat, p = fisher_exact(observed)   # only for 2×2 tables
```

**Sample size bias in significance:**

```python
# With n=10: practically large effect might not be significant
small_n = np.random.normal(5, 10, size=10)
baseline_small = np.random.normal(0, 10, size=10)
_, p = stats.ttest_ind(small_n, baseline_small)
print(f"n=10: p={p:.3f}")

# With n=100000: tiny, meaningless effect is highly significant
large_n = np.random.normal(0.01, 10, size=100_000)
baseline_large = np.random.normal(0, 10, size=100_000)
_, p = stats.ttest_ind(large_n, baseline_large)
print(f"n=100000: p={p:.3f}")   # p ~ 0.001 despite near-zero effect
# always compute Cohen's d alongside p
```

---

## A complete A/B test analysis example

```python
import numpy as np
from scipy import stats
from statsmodels.stats.proportion import proportions_ztest, proportion_effectsize
from statsmodels.stats.power import zt_ind_solve_power

np.random.seed(42)

# Simulated data: users randomly assigned to control or treatment
n_control  = 5000
n_treat    = 5000
conv_ctrl  = np.random.binomial(1, p=0.05, size=n_control)   # 5% baseline
conv_treat = np.random.binomial(1, p=0.062, size=n_treat)    # 6.2% after treatment

p_ctrl  = conv_ctrl.mean()
p_treat = conv_treat.mean()
print(f"Control:   {p_ctrl:.3%}")
print(f"Treatment: {p_treat:.3%}")
print(f"Relative lift: {(p_treat - p_ctrl) / p_ctrl:.1%}")

# Two-proportion z-test
count = np.array([conv_treat.sum(), conv_ctrl.sum()])
nobs  = np.array([n_treat, n_control])
stat, p = proportions_ztest(count, nobs)
print(f"z={stat:.3f}, p={p:.4f}")

# 95% CI on the difference
diff = p_treat - p_ctrl
se = np.sqrt(p_ctrl*(1-p_ctrl)/n_control + p_treat*(1-p_treat)/n_treat)
ci = diff + np.array([-1, 1]) * 1.96 * se
print(f"Absolute diff: {diff:.4f}  95% CI: [{ci[0]:.4f}, {ci[1]:.4f}]")

# Effect size
h = proportion_effectsize(p_ctrl, p_treat)
print(f"Cohen's h = {h:.3f}")

# Post-hoc power (what power did we achieve?)
achieved_power = zt_ind_solve_power(effect_size=abs(h), nobs1=n_control,
                                    alpha=0.05, ratio=1, alternative='two-sided')
print(f"Achieved power: {achieved_power:.2%}")
```

---

## Checkpoint

You are ready to move forward when you can, without looking anything up:

1. State the CLT formally and explain why it enables t-tests on non-normal data when n is large.
2. Compute a 95% CI for a sample mean using `scipy.stats.t.interval` given the sample, and state precisely what the 95% probability refers to.
3. Distinguish Type I and Type II errors, state their rate parameters, and explain the tradeoff between them.
4. State what p=0.04 means and list three things it does *not* mean.
5. Explain p-hacking by early stopping: why does checking the p-value daily increase the Type I error rate beyond α?
6. Apply Bonferroni correction when running 10 tests at α=0.05, and state why it is conservative.
7. Describe Benjamini-Hochberg FDR correction in one sentence and state when you would prefer it over Bonferroni.
8. State two assumption violations that would make a two-sample t-test invalid and the alternative test for each.
9. Write the five steps for designing an A/B test — in order, from defining the metric to analyzing the result.
10. State three causal mechanisms that produce correlation without causation and give a real-world example for one.
