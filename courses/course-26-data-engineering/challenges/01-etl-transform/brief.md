# ETL Transform: Parse, Clean, Derive

An on-call alert fires at 2 AM: the downstream aggregation job produced nonsense revenue figures. Post-mortem: someone ingested raw event data directly without running it through the type-normalisation layer. The field `amount_str` has currency symbols, thousand-separators, and mixed locales. Dates arrive in three different string formats. Status values like `"DELETED"` were never filtered. And a `_junk` column full of nulls has been growing the serialised file by 15 % for six months.

Your job: implement the ETL transform so the output frame matches the target schema exactly.

## Work directory

`setup.sh` plants the following in `~/.kube-dojo-work/01-etl-transform/`:

```
~/.kube-dojo-work/01-etl-transform/
├── data/
│   └── raw.csv          # seeded messy CSV (fixed seed — do not regenerate)
├── transform.py         # stub — implement run_transform() here
└── tests/
    └── test_transform_visible.py   # five visible sanity checks; run these during development
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/01-etl-transform
python3 -m venv .venv && . .venv/bin/activate
pip install pytest pandas
```

## Mission

Implement `run_transform()` in `transform.py`. It must:

1. Read `data/raw.csv` relative to the script's own directory.
2. Apply the following cleaning rules:

| Column in raw CSV | Rule | Output column |
|---|---|---|
| `id` | cast to `int64` | `id` |
| `user_name` | strip leading/trailing whitespace | `user_name` |
| `amount_str` | strip `$`, `,`, spaces; cast to `float64` | `amount_usd` |
| `event_ts` | parse to `datetime64[ns]` — mixed ISO + `DD/MM/YYYY HH:MM:SS`; use `format="mixed", dayfirst=True` | `event_date` |
| `category` | lowercase, strip whitespace | `category` |
| `_junk` | drop entirely | — |
| rows where `status == "DELETED"` | drop entirely | — |
| `status` | drop after filtering | — |

3. Return the cleaned `pd.DataFrame` with **exactly** these columns in order: `id`, `user_name`, `amount_usd`, `event_date`, `category`.

### Target schema

| Column | dtype |
|---|---|
| `id` | `int64` |
| `user_name` | `object` (str) |
| `amount_usd` | `float64` |
| `event_date` | `datetime64[ns]` |
| `category` | `object` (str) |

Rows where `status` is `"DELETED"` must be absent. All other rows must be present. Order must match the source order (after drops).

## Why this matters

Downstream ML features and financial aggregations break silently when types are wrong — `"$1,234.00"` summed as a string is 0. Forcing an explicit typed contract at the pipeline boundary is the single highest-ROI change in most early-stage data platforms. The verifier checks both dtypes and values, not just shape.

## Verify

```bash
bash courses/course-26-data-engineering/challenges/01-etl-transform/verify.sh
```

All hidden assertions green → flag printed.
