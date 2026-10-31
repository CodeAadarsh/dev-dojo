# EDA & Visualization

> **Module 03 · Course 21** — Every modeling failure I've seen at SAP had a visible warning in the data that a proper EDA would have caught: a bimodal distribution that looked unimodal at default bin sizes, an outlier customer worth 500x the median that was pulling every regression coefficient, a date column whose distribution showed a sharp cliff the day the logging format changed. Visualization is not decorative — it is the fastest anomaly detector you have.

The goal of this module is to make EDA a repeatable, systematic workflow rather than ad-hoc scatterplots, and to make you fluent enough with matplotlib/seaborn that the tool never slows down the thought.

---

## The EDA workflow

EDA is iterative, not linear. A practical sequence for any new dataset:

```
1. Shape & schema check          df.shape, df.dtypes, df.head(), df.info()
        ↓
2. Missing data audit            df.isnull().mean().sort_values(ascending=False)
        ↓
3. Univariate distributions      one column at a time: histogram, KDE, box plot, value_counts
        ↓
4. Bivariate relationships       scatter, correlation heatmap, grouped distributions
        ↓
5. Temporal structure (if any)   time-series line plots, seasonal decomposition
        ↓
6. Segment comparisons           split by a categorical and compare distributions
        ↓
7. Anomaly & outlier detection   z-scores, IQR fences, pairplots
        ↓
8. Hypotheses to test            write down 3–5 specific questions for the modeling phase
```

Each step can send you back to a previous step. When step 3 reveals a bimodal distribution, go back to step 2 — there may be a latent grouping variable you missed.

---

## Summary statistics — the first pass

```python
import pandas as pd
import numpy as np

df = pd.read_csv("orders.csv")

# --- Step 1: shape and schema ---
df.shape          # (n_rows, n_cols)
df.dtypes         # column types
df.info()         # dtypes + non-null counts + memory usage
df.head()         # first 5 rows — spot obvious anomalies
df.sample(10)     # random 10 — less biased than head()

# --- Step 2: missing data ---
missing = df.isnull().mean().sort_values(ascending=False)
missing[missing > 0]                    # only columns with any nulls
# display as a bar chart later

# --- Step 3: numeric summary ---
df.describe()
# shows: count, mean, std, min, 25%, 50%, 75%, max for every float/int column
# key signals:
#   mean >> median (50%) → right skew
#   min = max → constant column → drop
#   min is a large negative → check for sentinel values (−999, −1)
#   count << n_rows → missing data not captured by isnull()

# extended describe including all dtypes
df.describe(include='all')   # adds unique/top/freq for object columns

# per-column: targeted
df['revenue'].describe()
df['revenue'].quantile([0.01, 0.05, 0.95, 0.99])  # tail behavior
df['revenue'].skew()    # >0 right skew, <0 left skew
df['revenue'].kurt()    # kurtosis — heavy tails if large positive
```

For categorical columns:

```python
df['region'].value_counts()              # frequency table
df['region'].value_counts(normalize=True)  # as proportions
df['status'].nunique()                   # number of distinct values
df['order_id'].duplicated().sum()        # check for duplicate keys
```

**Signals to flag immediately:**
- Any column with 0% variance (all identical values) — drop it.
- Any column with > 80% missing — decide upfront if you can impute or must drop.
- Numeric columns with value_counts showing exactly −1, −999, 0, or 9999 as the most common values — likely sentinel codes, not real data.
- `count` in `.describe()` less than `len(df)` with no NaN shown by `.isnull()` — sentinel-as-float masking real nulls.

---

## Distributions — histograms, KDE, and box plots

### matplotlib fundamentals

Before seaborn: understand the matplotlib object model. Every seaborn call creates a matplotlib figure internally; knowing the layers lets you customize anything.

```
Figure  ─── top-level canvas
└── Axes  ─── one "subplot" with its own coordinate system
      ├── x-axis, y-axis (with ticks, labels, spine)
      ├── artists: Line2D, PathCollection (scatter), Patch (bar/rect), Text
      └── legend, title
```

```python
import matplotlib.pyplot as plt

# explicit Figure + Axes creation — preferred over plt.plot()
fig, ax = plt.subplots(figsize=(8, 4))

ax.plot([1, 2, 3], [4, 5, 6], color='steelblue', linewidth=2, label='series A')
ax.scatter([1, 2, 3], [4.2, 5.1, 5.9], color='tomato', s=60, label='data')
ax.set_xlabel("x label")
ax.set_ylabel("y label")
ax.set_title("My Plot")
ax.legend()
ax.grid(True, linestyle='--', alpha=0.5)

plt.tight_layout()
plt.savefig("plot.png", dpi=150)   # always save to file in scripts
plt.show()                          # display inline in Jupyter
```

Always create `fig, ax = plt.subplots(...)` explicitly. Using `plt.plot()` directly is fine for one-off exploration but breaks as soon as you have multiple subplots.

### Multiple subplots

```python
fig, axes = plt.subplots(2, 3, figsize=(14, 8))
# axes is a (2, 3) ndarray of Axes objects

axes[0, 0].hist(df['revenue'], bins=50, color='steelblue', edgecolor='white')
axes[0, 1].boxplot(df['revenue'].dropna())
# ... etc.

plt.tight_layout()
```

### Histograms

```python
import seaborn as sns
sns.set_theme(style='whitegrid', palette='muted')

fig, axes = plt.subplots(1, 2, figsize=(12, 4))

# raw histogram
axes[0].hist(df['revenue'], bins=50, color='steelblue', edgecolor='white')
axes[0].set_title("Revenue Distribution (50 bins)")

# log scale when distribution spans orders of magnitude
axes[1].hist(df['revenue'], bins=50, color='steelblue', edgecolor='white', log=True)
axes[1].set_title("Revenue — log y scale")

plt.tight_layout()
```

**Bin count matters more than people think.** A Poisson-distributed count column with only 5 unique values looks uniform at `bins=50` — every bar height is 0 except 5 positions. Set bins equal to the number of unique integer values for discrete columns.

### KDE (Kernel Density Estimate)

A KDE is a smoothed version of the histogram — a sum of Gaussian kernels centered at each data point. Useful for comparing multiple distributions on the same axes.

```python
fig, ax = plt.subplots(figsize=(8, 4))

for region, group in df.groupby('region'):
    group['revenue'].plot.kde(ax=ax, label=region, linewidth=2)

ax.set_xlabel("Revenue")
ax.legend()
ax.set_title("Revenue KDE by Region")
```

Or with seaborn:

```python
sns.kdeplot(data=df, x='revenue', hue='region', ax=ax, fill=True, alpha=0.3)
```

### Box plots and violin plots

```python
# box: shows median, IQR, whiskers (1.5×IQR), outliers as points
fig, axes = plt.subplots(1, 2, figsize=(14, 5))

sns.boxplot(data=df, x='region', y='revenue', ax=axes[0])
axes[0].set_title("Revenue by Region (box)")

# violin: box + KDE rotated — shows distribution shape, not just quartiles
sns.violinplot(data=df, x='region', y='revenue', ax=axes[1], inner='box')
axes[1].set_title("Revenue by Region (violin)")

plt.tight_layout()
```

When to use each:
- **Histogram** — single variable, absolute counts, bin shape
- **KDE** — comparing distributions across groups, continuous shape
- **Box plot** — quick quartile + outlier summary; good for many groups side-by-side
- **Violin** — box + distribution shape; reveals bimodality that box plots hide

---

## seaborn plot families

seaborn organizes plots into three families.

### Distribution plots

```python
# univariate distribution: histogram + KDE together
sns.histplot(data=df, x='revenue', bins=40, kde=True, ax=ax)

# empirical CDF — useful for reading off percentiles directly
sns.ecdfplot(data=df, x='revenue', ax=ax)

# bivariate distribution: 2D histogram
sns.histplot(data=df, x='revenue', y='order_count', ax=ax)

# bivariate KDE
sns.kdeplot(data=df, x='revenue', y='order_count', fill=True, ax=ax)
```

### Relational plots

```python
# scatter
sns.scatterplot(data=df, x='ad_spend', y='revenue', hue='region',
                size='order_count', sizes=(20, 200), ax=ax)

# line — time series or sorted x
sns.lineplot(data=daily_df, x='date', y='revenue', hue='product', ax=ax)

# auto-faceting with relplot (creates its own Figure)
sns.relplot(data=df, x='ad_spend', y='revenue', hue='region', col='quarter',
            kind='scatter', height=4, aspect=1.2)
```

### Categorical plots

```python
# bar — shows mean ± 95% CI by default
sns.barplot(data=df, x='region', y='revenue', ax=ax)

# count — frequency of each category
sns.countplot(data=df, x='region', order=df['region'].value_counts().index, ax=ax)

# strip + box together
sns.boxplot(data=df, x='region', y='revenue', ax=ax, color='lightgrey')
sns.stripplot(data=df, x='region', y='revenue', ax=ax, alpha=0.3, jitter=True)

# swarm — like strip but non-overlapping (slow for large n)
sns.swarmplot(data=df, x='region', y='revenue', ax=ax, size=3)
```

---

## Correlation heatmaps

```python
# compute pairwise Pearson correlation
corr = df[numeric_cols].corr()

fig, ax = plt.subplots(figsize=(10, 8))
mask = np.triu(np.ones_like(corr, dtype=bool))   # hide upper triangle (redundant)

sns.heatmap(
    corr,
    mask=mask,
    annot=True,          # show coefficient value in each cell
    fmt='.2f',
    cmap='RdBu_r',       # diverging: red=negative, blue=positive, white=zero
    center=0,            # white at 0
    vmin=-1, vmax=1,
    square=True,
    linewidths=0.5,
    ax=ax,
)
ax.set_title("Pearson Correlation Matrix")
plt.tight_layout()
```

**Reading a heatmap:**
- Dark blue near 1.0 — strong positive correlation — two columns move together. If they are features, consider collinearity.
- Dark red near −1.0 — strong negative correlation — one increases as the other decreases.
- Any feature column with |r| > 0.8 against the target is worth investigating. Any two feature columns with |r| > 0.9 are likely redundant.

**Pairplot** — scatter for every pair + univariate on the diagonal:

```python
sns.pairplot(df[['revenue', 'orders', 'ad_spend', 'region']], hue='region',
             plot_kws={'alpha': 0.5, 's': 20}, diag_kind='kde')
```

Use pairplot on a *sample* of large DataFrames — it renders n² scatter plots, which gets slow above 1M rows. Use `df.sample(5000)`.

---

## Reading plots — skew, outliers, patterns

### Skewness

```
Right skew (positive skew):          Left skew (negative skew):
    │▓▓                                          ▓▓│
    │▓▓▓                                       ▓▓▓│
    │▓▓▓▓▓                                 ▓▓▓▓▓│
    │▓▓▓▓▓▓▓▓▓▓▓▓─────────              ──────▓▓▓▓▓▓▓▓▓▓▓│
  low               high              low               high

  mean > median                        mean < median
  e.g. revenue, response times        e.g. exam scores (easy exam)
```

Right-skewed distributions are common in revenue, latency, and usage metrics. Log-transform before feeding to linear models that assume normality.

```python
df['log_revenue'] = np.log1p(df['revenue'])   # log(1+x) handles zeros safely
sns.histplot(df['log_revenue'], kde=True, ax=ax)
```

### Outliers

An outlier is not always an error — it may be the most important data point. The questions to ask:
1. Is this value *mechanically* impossible? (negative age, >100% completion rate)
2. Does it come from a different data-generating process? (a B2B customer in a B2C dataset)
3. Does it disproportionately influence the analysis?

```python
# IQR fences — Tukey's method
Q1, Q3 = df['revenue'].quantile([0.25, 0.75])
IQR = Q3 - Q1
lo, hi = Q1 - 1.5 * IQR, Q3 + 1.5 * IQR
outliers = df[(df['revenue'] < lo) | (df['revenue'] > hi)]
print(f"{len(outliers)} outliers ({len(outliers)/len(df):.1%} of data)")

# z-score method (assumes roughly normal)
from scipy import stats
z = np.abs(stats.zscore(df['revenue'].dropna()))
outliers_z = df[z > 3]
```

Box plots show IQR-fence outliers as dots beyond the whiskers. Violin plots show whether they form a real secondary cluster.

### Temporal patterns

```python
df['created_at'] = pd.to_datetime(df['created_at'])
daily = df.set_index('created_at').resample('D')['revenue'].sum()

fig, ax = plt.subplots(figsize=(14, 4))
daily.plot(ax=ax, color='steelblue')
ax.set_title("Daily Revenue")
ax.set_ylabel("Revenue")

# check for data gaps (missing days)
full_range = pd.date_range(daily.index.min(), daily.index.max(), freq='D')
missing_days = full_range.difference(daily.index)
print(f"Missing days: {len(missing_days)}")
```

A sudden cliff in a time series is almost always a pipeline event — a schema change, a new data source, a logging bug. Mark it before modeling or it becomes a spurious trend.

---

## Debugging visualizations

### Misleading axes

**Truncated y-axis** — the most common deception (intentional or not):

```python
# creates a chart where a 1% difference looks enormous
ax.set_ylim(99.0, 100.0)   # y-axis starts at 99, not 0 — amplifies tiny differences

# fix: start at 0 for bar charts and counts
ax.set_ylim(0, None)        # explicit zero base
```

Dual y-axes are almost always misleading — the relationship between two series appears to change depending on how you scale the second axis. Use normalized versions of both series instead.

**Log scale without labeling it:**

```python
ax.set_yscale('log')
ax.set_ylabel("Revenue (log scale)")   # always label when using log scale
```

### Over-plotting

When scatter plots have many data points, dots overlap and you lose density information.

```python
# Option 1: transparency
ax.scatter(x, y, alpha=0.05, s=5)

# Option 2: hexbin density
ax.hexbin(x, y, gridsize=40, cmap='Blues')
fig.colorbar(ax.collections[0], ax=ax)   # add colorbar

# Option 3: 2D histogram
sns.histplot(data=df, x='x_col', y='y_col', bins=50, ax=ax)

# Option 4: sample
sample = df.sample(5000, random_state=42)
sns.scatterplot(data=sample, x='x_col', y='y_col', ax=ax)
```

### Correlation does not imply causation

A correlation heatmap showing `ad_spend` highly correlated with `revenue` does not mean advertising drives revenue. It may be that:
- High-revenue periods drive more ad spend (reverse causality)
- A third variable (product launch, seasonal demand) drives both
- The company increases ad spend *in anticipation* of high-revenue quarters

EDA surfaces correlations. Causal claims require controlled experiments or causal inference methods (difference-in-differences, instrumental variables, RCTs). Write EDA findings as "X correlates with Y" — not "X causes Y."

### Color choices

```python
# Never use rainbow (jet) — it has misleading perceptual non-linearity
# For sequential data: 'Blues', 'viridis', 'YlOrRd'
# For diverging data (with a meaningful center): 'RdBu', 'coolwarm', 'PiYG'
# For categorical (< 10 categories): sns.color_palette('tab10') or 'Set2'

sns.set_palette('Set2')   # colorblind-friendly categorical palette
```

Never use red/green alone to encode information — 8% of men are red-green colorblind. Add shape or pattern redundancy.

---

## A complete EDA mini-pipeline

```python
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns

sns.set_theme(style='whitegrid', palette='muted', font_scale=1.1)

df = pd.read_csv("orders.csv", parse_dates=['created_at'])
TARGET = 'revenue'
NUMERIC = df.select_dtypes(include='number').columns.tolist()

# 1. Schema
print(df.info())
print(df.describe())

# 2. Missing data
fig, ax = plt.subplots(figsize=(10, 3))
(df.isnull().mean().sort_values(ascending=False)
   .plot.bar(ax=ax, color='tomato', edgecolor='white'))
ax.set_title("Fraction missing per column")
ax.set_ylabel("Missing fraction")
plt.tight_layout()

# 3. Target distribution
fig, axes = plt.subplots(1, 2, figsize=(12, 4))
sns.histplot(df[TARGET], bins=50, kde=True, ax=axes[0])
axes[0].set_title(f"{TARGET} distribution")
sns.histplot(np.log1p(df[TARGET]), bins=50, kde=True, ax=axes[1], color='tomato')
axes[1].set_title(f"log1p({TARGET})")
plt.tight_layout()

# 4. Correlation matrix
corr = df[NUMERIC].corr()
fig, ax = plt.subplots(figsize=(max(8, len(NUMERIC)), max(6, len(NUMERIC)-2)))
mask = np.triu(np.ones_like(corr, dtype=bool))
sns.heatmap(corr, mask=mask, annot=True, fmt='.2f', cmap='RdBu_r',
            center=0, vmin=-1, vmax=1, square=True, ax=ax)
ax.set_title("Correlation matrix")
plt.tight_layout()

# 5. Target by categorical segment
CAT_COLS = df.select_dtypes(include=['object', 'category']).columns
for col in CAT_COLS:
    if df[col].nunique() <= 20:
        fig, ax = plt.subplots(figsize=(10, 4))
        order = df.groupby(col)[TARGET].median().sort_values(ascending=False).index
        sns.boxplot(data=df, x=col, y=TARGET, order=order, ax=ax)
        ax.set_title(f"{TARGET} by {col}")
        ax.tick_params(axis='x', rotation=45)
        plt.tight_layout()
```

---

## Checkpoint

You are ready to move forward when you can, without looking anything up:

1. Name the eight steps of the EDA workflow in order and state what backward signal each step can send.
2. Write the three lines that compute and visualize the fraction of missing values per column.
3. Explain why the choice of bin count matters for histograms on discrete vs continuous variables.
4. Distinguish box plot, violin plot, and KDE in terms of what distributional information each one shows and hides.
5. State two ways to address over-plotting in a scatter plot with 1 million points.
6. Explain why `seaborn.barplot` and a standard histogram are fundamentally different despite both being bars.
7. State three questions you would ask before concluding that a high correlation in a heatmap is causal.
8. Write the matplotlib calls to create a 2×3 grid of subplots and address each Axes individually.
9. Explain what a sharp cliff in a daily time-series plot most likely indicates about the data pipeline.

-> Next: **Statistics & Probability for DS** — the theory behind the charts. A/B tests, confidence intervals, and hypothesis tests are only correct if the assumptions hold — this module covers what those assumptions actually are.
