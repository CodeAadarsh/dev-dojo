# Parquet Star Schema

The analytics team's query on the `orders` table is scanning 4 billion rows when filtering by date. The root cause: **one wide, denormalized table with no partitioning.** A lakehouse rewrite request comes in: *"Model it as a star schema and partition the fact table by event date. Reduce scan cost by 98% for daily queries."*

Dimensional modeling and Parquet partitioning are the two highest-leverage patterns in batch data engineering. This challenge implements both without a warehouse in the loop.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/05-parquet-star-schema/
├── transform.py            # stub — three functions to implement
├── data/
│   └── orders_raw.csv      # 200-row seeded denormalized dataset
└── tests/
    └── test_sample.py      # visible smoke tests
```

The raw dataset is a flat orders export:

| Column | Notes |
|--------|-------|
| `order_id` | unique per row |
| `order_date` | YYYY-MM-DD, 2024-01-01 through 2024-01-07 |
| `customer_id`, `customer_name`, `customer_email`, `customer_country` | customer attributes |
| `product_id`, `product_name`, `product_category`, `product_unit_price` | product attributes |
| `quantity`, `total_amount` | fact measures |

## Mission

Implement three functions in `transform.py`:

### `build_dim_customers(df) -> pd.DataFrame`
Extract the customer dimension. Columns: `customer_id`, `customer_name`, `customer_email`, `customer_country`. **One row per unique `customer_id`.** No duplicates.

### `build_dim_products(df) -> pd.DataFrame`
Extract the product dimension. Columns: `product_id`, `product_name`, `product_category`, `product_unit_price`. **One row per unique `product_id`.** No duplicates.

### `build_fact_orders(df) -> pd.DataFrame`
Build the fact table. Columns: `order_id`, `order_date`, `customer_id`, `product_id`, `quantity`, `total_amount`. **One row per order** (same count as raw). `order_date` must be a `datetime64` column (not string) — partition inference depends on it.

### `write_partitioned(fact_df, output_dir)`
Write `fact_df` to Parquet, **partitioned by `order_date`**, under `output_dir/fact_orders/`. Use `pyarrow.parquet.write_to_dataset` or pandas `to_parquet` with `partition_cols=["order_date"]`.

The partition layout must match:

```
output_dir/
  fact_orders/
    order_date=2024-01-01/
      *.parquet
    order_date=2024-01-02/
      *.parquet
    ...
```

## Conditions checked by the verifier

| Check | Details |
|-------|---------|
| dim_customers row count | equals number of unique customers in raw data |
| dim_customers no duplicate customer_id | `assert dim["customer_id"].nunique() == len(dim)` |
| dim_products row count | equals number of unique products in raw data |
| dim_products no duplicate product_id | same uniqueness check |
| fact_orders row count | equals raw row count (200) |
| fact_orders has only the 6 fact columns | no denormalized attributes left |
| Parquet partition directories exist | one dir per date value |
| Round-trip join reproduces expected rows | `fact JOIN dim_customers JOIN dim_products` recovers original measures |

## Why this matters

Partition pruning is the cheapest query optimization available: a `WHERE order_date = '2024-01-03'` query on a partitioned dataset opens exactly one directory. Without partitioning, every Parquet file is opened. At petabyte scale that's the difference between a 2-second query and a 40-minute cluster job.

The star schema removes attribute duplication: storing `customer_name` in every order row is 100× the storage of a foreign key join. More importantly, a SCD (Slowly Changing Dimension) update to a customer address only touches one row in `dim_customers`, not every fact row.

## Verify

```bash
bash courses/course-26-data-engineering/challenges/05-parquet-star-schema/verify.sh
```

All tests green → flag printed.
