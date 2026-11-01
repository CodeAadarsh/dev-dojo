# Storage & Modeling

> **Module 06 · Course 26** — The pipeline delivered the data. Now where does it live, and in what shape? The difference between a data warehouse that serves 200ms BI queries and one that grinds through 20-minute full-table scans is almost entirely storage layout and schema design — not hardware. This module covers the decisions that compound over years of data growth.

---

## Data Lake vs Warehouse vs Lakehouse

These are not just buzzwords — they encode different tradeoffs around schema enforcement, query performance, and storage cost.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│  Data Lake                  Data Warehouse              Lakehouse           │
│  ──────────                 ──────────────              ─────────           │
│  Object store (S3/GCS)      Columnar engine             Object store        │
│  Raw files (JSON, CSV,      (Redshift, BigQuery,        + open table format │
│  Parquet, Avro)             Snowflake)                  (Iceberg / Delta)   │
│                                                                             │
│  Schema-on-read             Schema-on-write             Schema-on-write     │
│  Cheap storage              Expensive compute           Cheap storage       │
│  Hard to query efficiently  Fast queries                Fast queries        │
│  No ACID                    ACID within engine          ACID via format     │
│  No time-travel             Limited                     Time-travel built-in│
│                                                                             │
│  "Dump it all in S3"        "ETL everything             "The best of both"  │
│                              into the warehouse"                            │
└─────────────────────────────────────────────────────────────────────────────┘
```

**The evolution in practice:** most orgs start with a warehouse (fast, managed, expensive), accumulate a parallel data lake for raw/ML data (cheap, flexible, unmanaged), then reach for a lakehouse layer (Iceberg/Delta on S3) to get ACID and time-travel without paying warehouse per-query prices.

At SAP scale, the lake holds the full-fidelity log archive (the 100GB+/day stream from LGTM), the warehouse holds the aggregated metrics and SLI tables, and Iceberg tables bridge them for ad-hoc ML training jobs that need reproducible historical snapshots.

---

## Columnar Formats: Parquet

Row-oriented storage (CSV, JSON) keeps all columns for a row together. Columnar storage (Parquet, ORC) keeps all values for a column together. The consequence for analytics:

```
Row store: SELECT sum(revenue) FROM orders
→ reads every row's all columns to get just the revenue column
→ I/O ∝ rows × columns

Columnar store: same query
→ reads only the revenue column's byte range
→ I/O ∝ rows × 1 (the one column needed)

On a 100-column schema: ~100× less I/O for a single-column aggregate.
```

### How Parquet stores data internally

```
┌───────────────────────────────────────────────────────────────────┐
│ Parquet File                                                      │
│  ┌─── Row Group 0 (128 MB default) ─────────────────────────────┐│
│  │  Column chunk: user_id    [min=1, max=99832, null_count=0]   ││
│  │  Column chunk: revenue    [min=0.01, max=4200.00]            ││
│  │  Column chunk: event_date [min=2024-01-01, max=2024-01-01]   ││
│  └───────────────────────────────────────────────────────────────┘│
│  ┌─── Row Group 1 ──────────────────────────────────────────────┐│
│  │  Column chunk: user_id    [min=99833, max=199100]            ││
│  │  ...                                                         ││
│  └───────────────────────────────────────────────────────────────┘│
│  ┌─── File Footer ──────────────────────────────────────────────┐│
│  │  Row group statistics + schema + column offsets              ││
│  └───────────────────────────────────────────────────────────────┘│
└───────────────────────────────────────────────────────────────────┘
```

The **footer statistics** (min/max/null_count per column chunk per row group) are the basis for **predicate pushdown**.

---

## Partitioning & Predicate Pushdown

Partitioning is directory-level filtering. Predicate pushdown is statistics-level filtering within a file.

### Partition pruning

```
# unpartitioned — full scan
s3://bucket/orders/
  orders.parquet          (all dates, all regions, 500 GB)

# partitioned by date
s3://bucket/orders/
  date=2024-01-01/part-0.parquet   (2 GB)
  date=2024-01-02/part-0.parquet   (2 GB)
  ...

SELECT * FROM orders WHERE date = '2024-01-01'
→ only reads date=2024-01-01/ — 2 GB instead of 500 GB
```

The query engine (`spark`, `duckdb`, `athena`) looks at the path prefix and skips irrelevant directories entirely — no file is opened.

### Predicate pushdown within a file

```python
import pyarrow.parquet as pq
import pyarrow.compute as pc

# Without pushdown: reads all row groups, filters in memory
table = pq.read_table("orders.parquet")
table = table.filter(pc.field("region") == "EU")

# With pushdown: reads footer first, skips row groups where max(region) < "EU"
table = pq.read_table(
    "orders.parquet",
    filters=[("region", "==", "EU")],   # pushed into the reader
)
```

Parquet column statistics let the reader skip entire row groups where the min/max range makes the predicate impossible. On a well-sorted dataset this can skip 90%+ of row groups.

### Choosing a partition key

| Key | Good when | Bad when |
|-----|-----------|----------|
| `date` | Most queries are time-bounded; data grows by date | Data is queried by user_id or product; date is irrelevant |
| `region` | Multi-region architecture; queries are per-region | Very high cardinality (>10k values) → too many tiny dirs |
| `(date, region)` | Queries always specify both | Creates a 2D grid; 30 dates × 50 regions = 1500 dirs, some empty |
| `user_id` (high cardinality) | Almost never | Many tiny files; metadata overhead kills listing |

**High-cardinality partition keys are the #1 cause of slow object-store queries.** Listing 100k partition directories to find the right subset is slower than a full scan of a well-compressed monolithic file.

---

## Table Formats: Iceberg & Delta (Concepts)

Open table formats add a **metadata layer** on top of Parquet files in object storage. Instead of a directory scan to enumerate files, a query engine reads a manifest that tells it exactly which files are part of the current table snapshot.

```
Delta Lake / Iceberg structure:
  s3://bucket/orders/
    _delta_log/ or metadata/
      00000000000000000000.json   ← snapshot 0: these 10 files are the table
      00000000000000000001.json   ← snapshot 1: added 3 files, deleted 2
      ...
    data/
      date=2024-01-01/part-0.parquet
      date=2024-01-01/part-1.parquet
      ...
```

Key capabilities you get for free:

| Capability | What it means |
|------------|--------------|
| **ACID transactions** | Concurrent writers don't corrupt each other; reads see a consistent snapshot |
| **Schema evolution** | Add/rename/drop columns without a full rewrite |
| **Time travel** | `SELECT * FROM orders VERSION AS OF 42` (snapshot ID) or `AS OF TIMESTAMP '...'` |
| **Partition evolution** | Change the partition scheme without rewriting all data |
| **Z-ordering / clustering** | Co-locate related rows to improve multi-dimensional predicate pushdown |

**Iceberg vs Delta:** functionally near-equivalent for most use cases. Iceberg has stronger multi-engine support (Spark, Trino, Flink, DuckDB, BigQuery). Delta Lake has deeper Spark integration and a richer open-source ecosystem (Delta Sharing, Unity Catalog). At SAP, if you're on Databricks, Delta. If you're on a non-Databricks stack (EMR, Trino, open), Iceberg.

---

## Dimensional Modeling

Dimensional modeling is the schema design pattern for analytics workloads. It optimizes for query readability and aggregation performance, not for write normalization.

### Star schema

```
                        ┌────────────────────────┐
                        │  dim_date               │
                        │  date_key (PK)          │
                        │  day, month, quarter,   │
                        │  is_weekend, fiscal_qtr │
                        └───────────┬─────────────┘
                                    │ FK
              ┌────────────────┐    │    ┌─────────────────────┐
              │  dim_customer  │    │    │  dim_product         │
              │  customer_key  │    │    │  product_key         │
              │  name, region, │    │    │  name, category,     │
              │  segment, tier │    │    │  unit_price          │
              └───────┬────────┘    │    └──────────┬───────────┘
                      │ FK          │               │ FK
                      └────────────►───────────────┘
                                    │
                        ┌───────────▼─────────────┐
                        │  fact_orders             │
                        │  order_key (PK)          │
                        │  customer_key (FK)       │
                        │  product_key  (FK)       │
                        │  date_key     (FK)       │
                        │  quantity, revenue,      │
                        │  discount, cost          │
                        └─────────────────────────┘
```

**Fact tables** store measurements (metrics, events, transactions). They are wide (many rows) and narrow (only FKs + measures). **Dimension tables** store context (who, what, when, where). They are narrow (fewer rows) and wide (many descriptive columns).

Key design rules:
- Surrogate keys (auto-increment integers) as PKs and FKs — not business keys, which change.
- All measures in the fact table are **additive** across all dimensions, or explicitly **semi-additive** (only some dims) or **non-additive** (ratios, percentages — store numerator and denominator separately).
- Denormalize dimensions aggressively. In OLTP you normalize to avoid update anomalies. In a warehouse there are no updates to dimension attributes (or they go through SCD), so flattening is correct.

### Slowly Changing Dimensions (SCD)

When a dimension attribute changes (a customer moves regions, a product is renamed), how do you handle it?

| Type | Behavior | Keeps history? | Use case |
|------|----------|----------------|----------|
| **SCD 0** | Ignore the change — original value stays | No | Static attributes (birthdate, signup country) |
| **SCD 1** | Overwrite — current value only | No | Correcting errors; "current state" reporting |
| **SCD 2** | Add a new row with `valid_from`/`valid_to` + `is_current` | Yes | Historical reporting ("what region was this customer in during this order?") |
| **SCD 3** | Add a `prev_value` column | Partial (one step) | Rare; when you care only about the immediate predecessor |

SCD 2 is the one worth mastering:

```sql
-- Current state
SELECT * FROM dim_customer WHERE is_current = true;

-- State at a specific order time
SELECT
    o.order_key,
    c.region,        -- region AS IT WAS when the order was placed
    o.revenue
FROM fact_orders o
JOIN dim_customer c
  ON o.customer_key = c.customer_key
  AND o.order_date BETWEEN c.valid_from AND c.valid_to;
```

Without SCD 2, a customer who moved regions would have all historical orders attributed to their current region — silently wrong.

---

## dbt-Style Transforms

dbt (data build tool) popularized the **transform-in-the-warehouse** pattern: raw data lands in a `raw` schema, transformations are SQL `SELECT` statements tracked in Git, and dbt manages materialization and dependencies.

```
raw.events         (append-only landing table)
    └─ stg_events  (typed, cleaned, renamed — lightweight SELECT)
         └─ int_sessions  (session reconstruction — intermediate model)
              └─ fct_sessions, dim_users  (final marts)
```

Key conventions:
- **Models are `SELECT` statements** in `.sql` files. dbt wraps them in `CREATE TABLE AS` or `CREATE VIEW`.
- **`{{ ref('model_name') }}'`** replaces hardcoded schema.table — dbt injects the correct schema per environment (dev/staging/prod) and builds the dependency DAG for you.
- **Materializations:** `view` (freshest, no storage), `table` (full rebuild each run), `incremental` (only process new rows), `ephemeral` (CTE inlined, no storage).
- **Incremental models** are the most important optimization at scale:

```sql
-- fct_events.sql
{{ config(materialized='incremental', unique_key='event_id') }}

SELECT event_id, user_id, event_type, occurred_at
FROM {{ ref('stg_events') }}

{% if is_incremental() %}
  WHERE occurred_at >= (SELECT max(occurred_at) FROM {{ this }})
{% endif %}
```

On first run: full build. On subsequent runs: only events newer than the last run are processed and merged.

---

## Debugging Storage & Modeling

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| Query on Parquet takes minutes despite small result set | Too many tiny files (hundreds of 1–50 MB files); per-file open overhead dominates | Compact with a periodic `OPTIMIZE` (Delta) / `rewrite_data_files` (Iceberg), or batch writes to 256–512 MB files before writing |
| Partition-filtered query reads the whole dataset | Partition column written as string `"2024-01-01"` but query uses `date` type, or wrong column used for partitioning | Confirm partition column type matches query predicate type; use `EXPLAIN` to verify partition pruning is applied |
| Aggregation on fact table returns inflated numbers | Fact joined to SCD 2 dim without `valid_from`/`valid_to` filter — multiple dim rows per key match | Add `AND o.order_date BETWEEN d.valid_from AND d.valid_to` to every dim join; add `WHERE is_current = true` for current-state queries |
| `SELECT *` scan of a Parquet table is slower after schema evolution | New columns have no statistics in older row groups / files, so pushdown is disabled | Re-compact the table after major schema changes; new files will have correct statistics |
| SCD Type 1 update corrupts historical reports | `UPDATE dim_customer SET region = 'EU' WHERE id = 42` rewrites history | Never SCD 1 on reporting attributes; convert to SCD 2 and add `valid_from`/`valid_to`; audit for all direct `UPDATE` statements in transform pipelines |
| dbt incremental model slowly accumulates wrong rows | `unique_key` deduplication upsert has a bug, or `is_incremental()` watermark is on a non-monotonic column | Switch to a partition-replace incremental strategy; use `occurred_at` (immutable event time), not `updated_at` |

### Diagnosing tiny files

```python
import pyarrow.parquet as pq
import os

# Check file sizes and row counts before deciding whether to compact
dataset = pq.ParquetDataset("s3://bucket/orders/date=2024-01-01/")
for fragment in dataset.fragments:
    meta = fragment.metadata
    total_rows = sum(
        meta.row_group(i).num_rows for i in range(meta.num_row_groups)
    )
    size_mb = os.path.getsize(fragment.path) / 1e6   # local; use boto3 for S3
    print(f"{fragment.path}: {size_mb:.1f} MB, {total_rows:,} rows")
```

Aim for 256–512 MB per file, 50k–5M rows per row group. Below 10 MB per file is the tiny-file zone.

> **War story.** A product analytics team at a fintech built a dashboard on an Athena table partitioned by `(date, event_type, platform, country)` — four dimensions, cardinalities of 365 × 30 × 5 × 200 = 10.95 million partition combinations. A year of data had 2.3 million partition directories in S3, most with a single 4 KB file. A dashboard query that touched 90 days × all event types took 45 seconds — 90% of which was S3 `ListObjects` API calls on millions of prefixes. The fix was to collapse to a single `date` partition and add Z-ordering on `event_type` and `country` inside each file (Delta Lake). The same query dropped to 3.2 seconds. The lesson: **high-cardinality partition keys are a performance trap, not a performance feature.** Partition for the dominant query time filter; use columnar statistics for everything else.

---

## Checkpoint

You're solid on storage and modeling when you can, without looking anything up:

1. Explain predicate pushdown: what data structure inside a Parquet file enables the reader to skip row groups, and what column property must be present?
2. You have 500 files of 2 MB each in a date partition. What problem does this cause, what causes it, and what is the fix?
3. Describe the difference between a fact table and a dimension table. Why are dimension tables denormalized?
4. A customer moved from `region=US` to `region=EU` on 2024-06-01. You need to report total revenue by region per historical order date accurately. Which SCD type do you use, what columns does `dim_customer` have, and what does the JOIN condition look like?
5. What does `mode="incremental"` in dbt do differently from `mode="table"`, and what is the risk of using a non-monotonic watermark column?
6. You run `EXPLAIN` on a Parquet query and see `TableScan (partitions read: 365/365)`. The query has `WHERE date = '2024-01-01'`. What is wrong and how do you fix it?
7. Explain the core capability that Iceberg/Delta adds over raw Parquet on S3 that enables ACID writes. What data structure does the format maintain to track which files belong to the current table snapshot?

➡ Next up: **Data Quality & Governance** — the discipline of knowing when your data is wrong before your stakeholders do.
