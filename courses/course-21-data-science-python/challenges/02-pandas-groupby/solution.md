# Solution — Pandas GroupBy — Clean and Aggregate

## Complete solution

```python
import pandas as pd


def clean(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()

    # 1. Drop rows where order_id is "N/A" (or any non-numeric string)
    df = df[pd.to_numeric(df["order_id"], errors="coerce").notna()].copy()

    # 2. Cast order_id to int64
    df["order_id"] = df["order_id"].astype("int64")

    # 3. Title-case region ("north" -> "North", "NORTH" -> "North")
    df["region"] = df["region"].str.title()

    # 4. Strip "$" and commas from amount, then cast to float64
    df["amount"] = (
        df["amount"]
        .astype(str)
        .str.replace(r"[$,]", "", regex=True)
        .astype("float64")
    )

    # 5. Cast quantity to int64
    df["quantity"] = df["quantity"].astype("int64")

    # 6. Parse date strings to datetime
    df["date"] = pd.to_datetime(df["date"])

    return df


def aggregate(df: pd.DataFrame) -> pd.DataFrame:
    return (
        df.groupby("region")
        .agg(
            total_amount=("amount", "sum"),
            total_quantity=("quantity", "sum"),
            order_count=("order_id", "count"),
        )
        .sort_index()
        .reset_index()
    )
```

## Why each step

### Dropping N/A order_ids

`pd.to_numeric(..., errors="coerce")` converts unparseable strings to `NaN` instead of raising. Filtering out `NaN` rows then leaves only genuine integer values. The `.copy()` after the filter avoids the pandas `SettingWithCopyWarning` when you later assign to columns.

### Title-casing regions

`str.title()` handles all of `"north"`, `"North"`, `"NORTH"` → `"North"`. If the data had apostrophes (e.g. `"o'brien"` → `"O'Brien"` incorrectly) you would use `.str.capitalize()` per word or a custom map, but title-case is the right tool here.

### Stripping currency formatting

`str.replace(r"[$,]", "", regex=True)` removes both `$` and `,` in one pass. The character class `[$,]` matches either character. Doing this before `astype(float)` prevents `ValueError: could not convert string to float: '$1,234.50'`.

### Casting quantity to int64

After dropping the N/A rows, the column still has `float64` dtype (because pandas upcasts to float to accommodate NaN during the read). Casting explicitly ensures the aggregate sum is an integer, which the verifier checks.

### The groupby aggregation

The named-aggregation syntax `agg(total_amount=("amount", "sum"), ...)` produces clean column names without a `.rename()` call. `.sort_index()` sorts by region alphabetically before `.reset_index()` moves the region from the index back into a column. This matters because the verifier sorts by region and checks the index is 0-based.

## Common mistakes

**Not calling `.copy()` after the filter row** — any subsequent `df["col"] = ...` raises a `SettingWithCopyWarning` (and may silently not propagate on certain pandas versions). Always `.copy()` after a boolean mask filter if you intend to mutate the result.

**Using `df["amount"].str.replace("$", "", regex=False)` and forgetting commas** — the `$` alone does not fix `"1,234.50"`. One regex `[$,]` handles both.

**`df["order_id"].astype(int)` without dropping N/A first** — this raises `ValueError: invalid literal for int() with base 10: 'N/A'`. Always filter before casting.

**Forgetting `.reset_index()` on the aggregate result** — without it, `region` is the DataFrame index, not a column, and the verifier's column check fails.
