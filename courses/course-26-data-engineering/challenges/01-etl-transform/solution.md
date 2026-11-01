# Solution: ETL Transform

## The complete implementation

```python
# transform.py
import os
import pandas as pd

DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")


def run_transform() -> pd.DataFrame:
    df = pd.read_csv(os.path.join(DATA_DIR, "raw.csv"))

    # 1. drop DELETED rows before anything else
    df = df[df["status"] != "DELETED"].copy()

    # 2. id: already numeric in the CSV but cast explicitly for safety
    df["id"] = df["id"].astype("int64")

    # 3. user_name: strip whitespace
    df["user_name"] = df["user_name"].str.strip()

    # 4. amount_str -> amount_usd: strip currency symbol, commas, spaces, cast to float
    df["amount_usd"] = (
        df["amount_str"]
        .str.replace(r"[$,\s]", "", regex=True)
        .astype("float64")
    )

    # 5. event_ts -> event_date: parse mixed formats
    #    pandas 2+ requires format="mixed" for per-element inference
    df["event_date"] = pd.to_datetime(df["event_ts"], format="mixed", dayfirst=True)

    # 6. category: lowercase and strip
    df["category"] = df["category"].str.strip().str.lower()

    # 7. select and reorder output columns (drops _junk, status, amount_str, event_ts)
    return df[["id", "user_name", "amount_usd", "event_date", "category"]].reset_index(drop=True)
```

## Why each piece is correct

**`df = df[df["status"] != "DELETED"].copy()`** — filter before deriving columns so downstream operations never see garbage from rows you're going to discard anyway. `.copy()` avoids the `SettingWithCopyWarning` on the subsequent mutations.

**`str.replace(r"[$,\s]", "", regex=True)`** — a single regex pass removes the dollar sign, thousand-separators, and any stray spaces. The alternative (`str.replace("$","").str.replace(",","")`) requires multiple string passes and misses locale variants like spaces used as separators.

**`pd.to_datetime(..., format="mixed", dayfirst=True)`** — the raw data has two date formats: ISO 8601 (`2024-01-15T08:30:00`) and `DD/MM/YYYY HH:MM:SS`. In pandas 2+ the automatic mixed-format inference was removed; you must pass `format="mixed"` so the parser infers the format per element. `dayfirst=True` resolves the ambiguity in the `DD/MM/YYYY` rows. Without `format="mixed"`, pandas applies the first element's format to every row and raises a `ValueError` on the `DD/MM/YYYY` entries.

**`.reset_index(drop=True)`** — after dropping rows the integer index has gaps (`0,1,3,4,…`). Resetting gives a clean `0..N-1` index that downstream joins and `.iloc` operations expect.

**Column selection at the end** — selecting `[["id","user_name","amount_usd","event_date","category"]]` in one final step is the safe way to both reorder and drop (`_junk`, `status`, `amount_str`, `event_ts`) without iterating over column names. The verifier checks exact column order.

## Where people get it wrong

- Forgetting `format="mixed"` and/or `dayfirst=True`: the ISO dates parse fine; only the `DD/MM/YYYY` rows break, and if none of the failing rows are in visible tests, you won't notice until the hidden suite.
- Mutating the filtered DataFrame in-place without `.copy()`: leads to `SettingWithCopyWarning` and, in pandas 2.x+, a `ChainedAssignmentError` that silently skips the assignment.
- Selecting `float` instead of `float64` in the dtype assertion: `astype("float")` is an alias for Python's native `float` (`float64` on 64-bit), but explicit `"float64"` is unambiguous and the verifier uses the pandas dtype string.
- Pandas 3.x uses `StringDtype` rather than `object` for string columns; the verifier uses `pd.api.types.is_string_dtype()` which accepts both, so either is fine.
