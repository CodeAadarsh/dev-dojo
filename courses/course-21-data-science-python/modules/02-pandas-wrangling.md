# pandas: Wrangling & Cleaning

> **Module 02 · Course 21** — pandas is where most real data work happens. Unlike NumPy, the interesting bugs here are not performance bugs — they are correctness bugs that produce the wrong answer silently. `SettingWithCopyWarning`, silent dtype promotion, and merge key explosions are not edge cases; they are the exact traps that cause bad model inputs and wrong dashboards. This module covers the full wrangling toolkit plus the failure modes.

Assumes you can already read a CSV and filter a DataFrame. The pitch here is the *internals* of the index, the *why* behind the warning, and the patterns that scale to a production data pipeline.

---

## Series and DataFrame — the internal model

A **Series** is a 1-D labeled array: a NumPy-backed data buffer plus an **Index** object that maps labels to integer positions.

```
Series(data=[10, 20, 30], index=['a', 'b', 'c'])

  index   data
  ───────────
  'a'  │  10
  'b'  │  20
  'c'  │  30

  internally: a NumPy array [10, 20, 30] + an Index(['a','b','c'])
  alignment on index is the key behavior that distinguishes Series from ndarray
```

A **DataFrame** is a dict of Series that all share the same Index. The columns are the dict keys.

```
df = pd.DataFrame({'price': [10, 20, 30],
                   'qty':   [1,  5,  2]},
                  index=['a', 'b', 'c'])

  index │ price │ qty
  ──────┼───────┼────
  'a'   │  10   │  1
  'b'   │  20   │  5
  'c'   │  30   │  2

  internally: RangeIndex([0,1,2]) or Index(['a','b','c'])
              + {'price': Series, 'qty': Series}
              all Series share the same Index object
```

**Index alignment** is pandas' most important (and most dangerous) feature. When you add two Series, pandas aligns them by label before operating — not by position.

```python
s1 = pd.Series([1, 2, 3], index=['a', 'b', 'c'])
s2 = pd.Series([10, 20, 30], index=['b', 'c', 'd'])

s1 + s2
# a     NaN    ← 'a' in s1, not in s2 → NaN
# b    22.0    ← 2 + 20
# c    33.0    ← 3 + 30
# d     NaN    ← 'd' in s2, not in s1 → NaN
```

This is almost always the right behavior for time-series data. It is almost always surprising the first time you see it with DataFrames.

---

## The Index — more than row numbers

The index is not just a row counter. It is a first-class data structure that can be:

- `RangeIndex(start=0, stop=n)` — the default after `read_csv`, nearly free memory-wise
- `Int64Index` / `Index` of arbitrary integers
- `Index` of strings (e.g., country codes, user IDs)
- `DatetimeIndex` — enables time-series operations
- `MultiIndex` — hierarchical, the output of `groupby` with multiple keys

```python
import pandas as pd

df = pd.read_csv("sales.csv")
df.index        # RangeIndex(start=0, stop=n, step=1) by default

# Set a meaningful index
df = df.set_index("order_id")
df.index        # Index(['A001', 'A002', ...], dtype='object', name='order_id')

# Reset back to integer index
df = df.reset_index()   # order_id becomes a regular column again
```

**When to set an index:** only when you regularly query by that column (`df.loc["A001"]`) or you are doing time-series operations. Do not set an index just because it looks cleaner — it complicates merges and some aggregations.

---

## Indexing — loc, iloc, and the [] trap

pandas has three indexing systems and choosing the wrong one is the root cause of most SettingWithCopyWarning issues.

| accessor | selects by | returns |
|----------|-----------|---------|
| `df.loc[row, col]` | **label** | scalar, Series, or DataFrame |
| `df.iloc[row, col]` | **integer position** | scalar, Series, or DataFrame |
| `df[col]` | column label (or boolean mask for rows) | Series or DataFrame |

```python
df = pd.DataFrame({'a': [1,2,3], 'b': [4,5,6]},
                  index=['x','y','z'])

# loc — label-based, inclusive on both ends of slices
df.loc['x']          # row with label 'x' → Series
df.loc['x':'y']      # rows x and y — INCLUSIVE of 'y' (unlike Python slicing)
df.loc['x', 'a']     # scalar: 1
df.loc[['x','z'], 'a']  # two rows, one column

# iloc — position-based, exclusive end (like Python)
df.iloc[0]           # first row → Series
df.iloc[0:2]         # rows 0 and 1 — 'z' excluded
df.iloc[0, 1]        # row 0, col 1 → 4

# [] — convenient but context-dependent
df['a']              # column 'a' → Series
df[['a', 'b']]       # two columns → DataFrame
df[df['a'] > 1]      # boolean filter → DataFrame
```

**The chained indexing trap:**

```python
# WRONG — may silently not modify df
df['b'][df['a'] > 1] = 99    # two separate operations: df['b'] then [mask]

# RIGHT — single .loc operation
df.loc[df['a'] > 1, 'b'] = 99
```

Chained indexing (`df['col'][mask]`) works in two steps. The first step `df['col']` may return a copy (pandas decides based on internal structure). Setting on a copy modifies the copy, not `df` — the value never lands. Use `.loc` for all assignment.

---

## Boolean filtering

```python
df = pd.read_csv("orders.csv")

# single condition
df[df['status'] == 'shipped']

# multiple conditions — use & | ~ with parentheses (not and/or/not)
df[(df['amount'] > 1000) & (df['status'] == 'shipped')]
df[(df['region'] == 'IN') | (df['region'] == 'SG')]
df[~df['cancelled']]               # boolean column

# isin — cleaner than chained OR
df[df['region'].isin(['IN', 'SG', 'US'])]

# str accessor
df[df['email'].str.endswith('@sap.com')]
df[df['name'].str.contains('kumar', case=False, na=False)]

# between (inclusive on both ends)
df[df['amount'].between(100, 500)]

# query — readable syntax for simple conditions
df.query("amount > 1000 and status == 'shipped'")
df.query("region in ['IN', 'SG'] and amount > @threshold")  # @var interpolation
```

---

## groupby — aggregate, transform, filter

The groupby-apply pattern is the pandas workhorse. Three distinct operations share the `.groupby()` syntax but have different semantics.

**Aggregate** — reduce each group to a scalar.

```python
df.groupby('region')['revenue'].sum()      # Series, one value per region
df.groupby('region')['revenue'].agg(['mean', 'std', 'count'])  # multiple
df.groupby(['region', 'product'])['revenue'].sum()  # multi-key groupby
df.groupby('region').agg({'revenue': 'sum', 'orders': 'count'})  # per-column
```

**Transform** — broadcast the group-level result back to the original shape. Output has the same index as the input.

```python
# subtract group mean (within-group demeaning)
df['revenue_demeaned'] = df.groupby('region')['revenue'].transform('mean')
# now each row has the mean of its region — for subtracting from df['revenue']

# rank within group
df['rank_in_region'] = df.groupby('region')['revenue'].transform(
    lambda s: s.rank(ascending=False)
)
```

`transform` is often confused with `agg`. The rule: if you need the result aligned back to the original DataFrame (same number of rows), use `transform`.

**Filter** — keep only groups satisfying a predicate.

```python
# keep only regions with more than 100 orders
df.groupby('region').filter(lambda g: len(g) > 100)
```

**named aggregation (pandas >= 0.25):**

```python
df.groupby('region').agg(
    total_revenue=('revenue', 'sum'),
    avg_order=('amount', 'mean'),
    n_orders=('order_id', 'count'),
)
```

The output columns are explicit and readable — prefer this over positional `agg` in production code.

---

## merge / join — the full picture

pandas `merge` is a SQL join. Understanding join types prevents the most costly data pipeline bugs.

```python
pd.merge(left, right, on='key', how='inner')   # default
pd.merge(left, right, on='key', how='left')
pd.merge(left, right, on='key', how='right')
pd.merge(left, right, on='key', how='outer')
pd.merge(left, right, left_on='order_id', right_on='id')  # different column names
pd.merge(left, right, on=['region', 'date'])  # multi-key
```

Visual:

```
left (orders)           right (customers)
id │ cust_id │ amt      id │ name
───┼─────────┼────      ───┼───────
 1 │    10   │ 100       10 │ Alice
 2 │    20   │ 200       20 │ Bob
 3 │    30   │  50       ← no order for cust 30

inner:  keeps rows where cust_id matches id in right  → rows 1,2
left:   keeps all of left + matches from right        → rows 1,2,3 (name NaN for row 3)
outer:  keeps all rows from both sides                → rows 1,2,3 + cust 30 with NaN
```

**Check for merge key explosions** — the silent data bug that inflates your DataFrame:

```python
# if 'key' is not unique in right, each left row matches multiple right rows
orders = pd.DataFrame({'order_id': [1,2], 'cust': ['A','B']})
events  = pd.DataFrame({'cust': ['A','A','B'], 'event': ['login','click','login']})

pd.merge(orders, events, on='cust')
# order_id  cust  event
#    1        A    login
#    1        A    click   ← order 1 appears TWICE
#    2        B    login
# expected 2 rows, got 3 — silent

# Always validate after merge
result = pd.merge(orders, events, on='cust')
assert len(result) == len(orders), "merge exploded — right side has duplicate keys"
```

Better: use `validate=` parameter (pandas >= 0.21):

```python
pd.merge(orders, customers, on='cust', how='left', validate='m:1')
# 'many-to-one': every key in left matches at most one in right
# raises MergeError if violated
# '1:1'  '1:m'  'm:1'  'm:m' are all valid
```

---

## Reshaping — pivot, melt, stack, unstack

**pivot_table** — wide form: rows are one variable, columns are another.

```python
df = pd.DataFrame({
    'region':  ['IN','IN','SG','SG'],
    'quarter': ['Q1','Q2','Q1','Q2'],
    'revenue': [100, 120, 80, 95]
})

pivot = df.pivot_table(values='revenue', index='region', columns='quarter', aggfunc='sum')
#          Q1   Q2
# region
# IN      100  120
# SG       80   95
```

**melt** — long form (the inverse of pivot): one row per observation.

```python
wide = pd.DataFrame({'country': ['IN','SG'],
                     'Q1': [100, 80],
                     'Q2': [120, 95]})

long = wide.melt(id_vars='country', var_name='quarter', value_name='revenue')
#   country quarter  revenue
# 0      IN      Q1      100
# 1      SG      Q1       80
# 2      IN      Q2      120
# 3      SG      Q2       95
```

Long form is what seaborn and most ML libraries expect. Wide form is what humans read. Convert between them liberally.

**stack/unstack** — pivot using the Index.

```python
pivot.stack()      # pivoted wide → stacked long, using the column index as a new level
pivot.unstack()    # inverse
```

---

## Missing data

pandas uses `NaN` (a IEEE 754 float) for missing numeric values and `pd.NA` / `None` for others.

```python
df.isnull().sum()          # count NaNs per column
df.isnull().mean()         # fraction missing per column
df.isnull().any(axis=1)    # mask of rows with any NaN

# Drop rows/columns
df.dropna()                # drop any row with a NaN
df.dropna(subset=['col'])  # only drop if NaN in this column
df.dropna(thresh=5)        # keep rows with at least 5 non-NaN

# Fill
df.fillna(0)
df['revenue'].fillna(df['revenue'].mean())
df.fillna(method='ffill')  # forward fill — carry last valid value forward
df.fillna(method='bfill')  # backward fill

# Interpolate (numeric columns only)
df['price'].interpolate(method='linear')
df['price'].interpolate(method='time')   # DatetimeIndex required

# Replace sentinel values before analysis
df.replace(-999, np.nan)                  # turn "missing code" into real NaN
df.replace({'status': {'N/A': None, 'n/a': None}})
```

**NaN propagates** through arithmetic, so one NaN in a Series makes `.sum()` return NaN unless you pass `skipna=True` (the default). The silent danger is at the *join* level: a left join introduces NaN for unmatched rows, and if you then feed a column with NaN into a model or a `groupby`, you get unexpected behavior.

---

## dtypes and categoricals

dtypes in pandas:

| dtype | memory | use |
|-------|--------|-----|
| `int64` | 8B/row | integers |
| `float64` | 8B/row | default float |
| `object` | 8B/row + heap | strings — slow for groupby/sort |
| `bool` | 1B/row | booleans |
| `datetime64[ns]` | 8B/row | timestamps |
| `category` | ~1–2B/row | low-cardinality strings |

**Categorical** dtype is critical for string columns with few unique values (enums, regions, status codes). pandas stores the unique values once and represents each row as a small integer code — 8–10x less memory and significantly faster groupby.

```python
df['region'] = df['region'].astype('category')
df['region'].cat.categories   # Index(['IN', 'SG', 'US'])
df['region'].cat.codes        # 0, 1, 2 ... (integer encoding)

# Ordered categorical — enables comparison operators and .min()/.max()
from pandas.api.types import CategoricalDtype
severity = CategoricalDtype(['low','medium','high','critical'], ordered=True)
df['severity'] = df['severity'].astype(severity)
df[df['severity'] >= 'high']   # works because ordered
```

**Read CSV with explicit dtypes** to avoid surprises:

```python
df = pd.read_csv("orders.csv", dtype={
    'order_id': str,      # prevent coercion to int that drops leading zeros
    'amount':   float,
    'region':   'category',
    'flag':     bool,
})
```

**parse_dates:**

```python
df = pd.read_csv("orders.csv", parse_dates=['created_at', 'shipped_at'])
df['created_at'].dtype   # datetime64[ns]
df['created_at'].dt.year    # .dt accessor
df['created_at'].dt.floor('D')   # truncate to day
```

---

## Method chaining

pandas supports a fluent method-chaining style that is cleaner than intermediate variable assignment. Use `.pipe()` for custom functions that don't fit the chain.

```python
# without chaining — lots of temp variables, hard to follow
df1 = df.rename(columns={'amt': 'amount'})
df2 = df1[df1['amount'] > 0]
df3 = df2.assign(amount_usd=lambda d: d['amount'] / 83.5)
df4 = df3.groupby('region')['amount_usd'].sum().reset_index()
df5 = df4.sort_values('amount_usd', ascending=False)

# with chaining
result = (
    df
    .rename(columns={'amt': 'amount'})
    .query('amount > 0')
    .assign(amount_usd=lambda d: d['amount'] / 83.5)
    .groupby('region')['amount_usd']
    .sum()
    .reset_index()
    .sort_values('amount_usd', ascending=False)
)
```

**`.assign()`** is the chaining-compatible way to add columns. It returns a new DataFrame, leaving the original untouched.

**`.pipe()`** for custom functions:

```python
def add_revenue_band(df, col='revenue'):
    df = df.copy()
    df['band'] = pd.cut(df[col], bins=[0, 1000, 5000, np.inf],
                        labels=['small','mid','large'])
    return df

result = (
    df
    .query('status == "paid"')
    .pipe(add_revenue_band, col='amount')
    .groupby('band')['amount'].mean()
)
```

---

## Debugging pandas

### SettingWithCopyWarning

```
SettingWithCopyWarning: A value is trying to be set on a copy of a slice from a DataFrame.
Try using .loc[row_indexer,col_indexer] = value instead
```

This warning means pandas *detected* that you may be writing to a copy. It fires on:

```python
# Common trigger 1 — chained indexing
filtered = df[df['region'] == 'IN']
filtered['revenue'] = filtered['revenue'] * 1.2   # warning — filtered may be a copy

# Fix: use .loc on the original, or .copy() explicitly
filtered = df[df['region'] == 'IN'].copy()
filtered['revenue'] = filtered['revenue'] * 1.2   # safe

# Or:
df.loc[df['region'] == 'IN', 'revenue'] *= 1.2    # single .loc — always safe
```

Whether `filtered` is a view or copy depends on the internal state of `df` (memory layout, whether it is already a slice, etc.). pandas cannot guarantee which — so it warns. The safe rule: **if you intend to modify a subset, call `.copy()` immediately, or do all mutations through `.loc` on the original DataFrame**.

### Silent dtype coercion

```python
df = pd.read_csv("orders.csv")
df['order_id'].dtype  # object — if the CSV had one row with 'VOID', everything became str
df['amount'].dtype    # object — one blank cell causes the whole column to be object

# diagnose
df.dtypes
df.select_dtypes(include='object').head()

# force-convert after inspection
df['amount'] = pd.to_numeric(df['amount'], errors='coerce')  # coerce converts bad values to NaN
df['order_id'] = df['order_id'].astype(str)
```

The classic trap: a numeric column becomes object because of a single header row duplicated mid-file, or a sentinel string like `"N/A"`. `pd.to_numeric(..., errors='coerce')` is safer than `.astype(float)` because it turns unparseable values into NaN instead of raising.

### Merge key explosions

Covered above, but the summary pattern:

```python
before = len(df_left)
result = pd.merge(df_left, df_right, on='key', how='left')
after = len(result)
if after > before:
    dups = df_right[df_right.duplicated(subset=['key'])]
    raise ValueError(f"merge inflated {before}→{after} rows; duplicate keys:\n{dups}")
```

Use `validate='m:1'` or `validate='1:1'` in `pd.merge` to raise automatically. Always validate expected cardinality.

### Index alignment surprises

```python
s1 = pd.Series([1, 2, 3])       # RangeIndex 0,1,2
s2 = pd.Series([10, 20, 30])    # RangeIndex 0,1,2

# After filter, index is preserved — not reset to 0,1,2
s3 = s1[s1 > 1]   # index [1, 2]
s3 + s2           # aligns by label: index [0,1,2], s3 has no label 0 → NaN at 0

# Fix: reset_index(drop=True) before arithmetic if you want position-based
s3 = s1[s1 > 1].reset_index(drop=True)
```

This bites hard when you filter a DataFrame, do computations, then try to assign the result back — the index gaps cause NaN fills.

---

## Checkpoint

You are ready to move forward when you can, without looking anything up:

1. Explain why `df['col'][mask] = val` is dangerous and write the correct `.loc` equivalent.
2. State the difference between `groupby.agg()` and `groupby.transform()` in terms of output shape.
3. Identify the merge type that can silently inflate row count and state the `validate=` argument that prevents it.
4. Convert a low-cardinality string column to `category` dtype in one line and state why this saves memory.
5. Write the `melt()` call to convert a wide DataFrame with columns `['country', 'Q1', 'Q2', 'Q3']` to long form.
6. Explain when `NaN` propagates silently through a groupby and how to detect it before it reaches your model.
7. State three reasons why `object` dtype on a numeric column should be treated as a bug.
8. Write a method chain that renames a column, filters rows, adds a derived column with `.assign`, groups by a key, and sorts the result.

-> Next: **EDA & Visualization** — before you model, you look. The EDA workflow shapes every modeling decision that follows.
