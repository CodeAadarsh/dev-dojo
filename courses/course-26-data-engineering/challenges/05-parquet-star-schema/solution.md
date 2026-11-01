# Solution — Parquet Star Schema

The complete `transform.py`. Key decisions below.

```python
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from pathlib import Path


def build_dim_customers(df: pd.DataFrame) -> pd.DataFrame:
    cols = ["customer_id", "customer_name", "customer_email", "customer_country"]
    return df[cols].drop_duplicates(subset=["customer_id"]).reset_index(drop=True)


def build_dim_products(df: pd.DataFrame) -> pd.DataFrame:
    cols = ["product_id", "product_name", "product_category", "product_unit_price"]
    return df[cols].drop_duplicates(subset=["product_id"]).reset_index(drop=True)


def build_fact_orders(df: pd.DataFrame) -> pd.DataFrame:
    cols = ["order_id", "order_date", "customer_id", "product_id", "quantity", "total_amount"]
    fact = df[cols].copy()
    fact["order_date"] = pd.to_datetime(fact["order_date"])
    return fact


def write_partitioned(fact_df: pd.DataFrame, output_dir: str) -> None:
    table = pa.Table.from_pandas(fact_df)
    pq.write_to_dataset(
        table,
        root_path=str(Path(output_dir) / "fact_orders"),
        partition_cols=["order_date"],
    )
```

## Why each piece is correct

**`drop_duplicates(subset=["customer_id"])`.**
The raw table has one row per order, so a customer who placed ten orders appears ten times. `drop_duplicates` on the key column collapses those to one. Using `subset=` rather than a full-row dedup is intentional: if two rows have the same `customer_id` but differ in a denormalized attribute (a data quality issue), you want the first occurrence, not a silent duplicate pass-through. Pair this with a uniqueness assertion in tests to catch upstream data problems.

**`pd.to_datetime(fact["order_date"])`.**
PyArrow infers Parquet column types from pandas dtypes. A string column is serialised as `BYTE_ARRAY` / `UTF8`; a `datetime64` column becomes `INT64` with `TIMESTAMP` logical type. The partition inference in `write_to_dataset` works on *values*, so strings like `"2024-01-03"` do work — but the round-trip dtype will be string on read. Converting to `datetime64` before writing ensures the Parquet schema is strongly typed, which matters for query engines that push date predicates down to partition pruning.

**`pq.write_to_dataset` vs `df.to_parquet`.**
Both accept `partition_cols`. `write_to_dataset` is the PyArrow-native API and gives you fine control over file naming, compression, and row-group size. `df.to_parquet(path, partition_cols=["order_date"], engine="pyarrow")` is the pandas shortcut that calls the same PyArrow internals. Either is accepted by the verifier.

**Why `fact_orders/` as the subdirectory.**
The Parquet dataset root should name the table. Hive-style partition paths are `<root>/<col>=<val>/part-0.parquet`. Putting the root at `output_dir/fact_orders/` keeps dims and facts in the same `output_dir` without path collision (future: `output_dir/dim_customers.parquet`).

## Star schema in the real world

```
dim_customers (customer_id PK)   dim_products (product_id PK)
       │                                  │
       └──────────── fact_orders ─────────┘
                     (order_id PK, customer_id FK, product_id FK,
                      order_date, quantity, total_amount)
                              │
                     partitioned by order_date
```

A query like `SELECT SUM(total_amount) FROM fact_orders JOIN dim_customers USING (customer_id) WHERE order_date = '2024-01-03' AND customer_country = 'IN'` opens exactly one partition directory and applies the country filter in-memory. Without the star schema you'd scan a 4-billion-row wide table; with it, you scan one partition of the narrow fact table and join a 20-row dim in memory.
