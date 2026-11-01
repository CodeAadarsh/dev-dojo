# Batch Processing & Spark

> **Module 04 · Course 26** — Spark is the dominant batch processing engine for large-scale data. You have almost certainly used it through a managed service (Databricks, AWS Glue, Dataproc). This module covers what actually happens under the hood: how the dataframe model maps to distributed execution, what shuffles cost and why avoiding them matters, how skewed data kills a job that looks fine on average, and how lazy evaluation lets you reason about query plans before they run. These are the concepts that separate someone who submits Spark jobs from someone who tunes them.

---

## The DataFrame Model and the Catalyst Optimizer

A Spark **DataFrame** is a distributed collection of rows with a named, typed schema. It is logically similar to a SQL table, but physically it is split across the cluster into **partitions** — each partition is a chunk of rows processed by a single executor core.

```
DataFrame: orders (10M rows)
┌────────────────────────────────────────────────────────────┐
│  Partition 0  │  Partition 1  │ ... │  Partition N-1        │
│  (rows 0-99K) │(rows 100-199K)│     │  (rows 9.9M-10M)     │
│  executor 1   │  executor 2   │     │  executor N           │
└────────────────────────────────────────────────────────────┘
```

You write transformations as DataFrame API calls (or SQL). Spark does not immediately execute them — instead it builds a **logical plan**, which the **Catalyst optimizer** rewrites (predicate pushdown, constant folding, column pruning), then converts to a **physical plan** that describes the actual execution stages.

```python
# This does NOT execute immediately — it builds a logical plan
result = (
    spark.read.parquet("s3://bucket/orders/")
    .filter("status = 'paid'")           # Catalyst pushes this into the scan
    .join(customers, "customer_id")      # Catalyst may reorder this
    .groupBy("region")
    .agg(F.sum("amount").alias("total"))
)

# Execution happens here — at an action
result.write.parquet("s3://bucket/daily-revenue/")
```

**Catalyst's most important optimization: predicate pushdown.** If you filter on a column that is also a Parquet partition key, Spark skips reading entire files. A `WHERE date = '2026-10-31'` filter on a Parquet dataset partitioned by `date` reads only one day's files — 1/365 of the data. This is why partitioning your storage correctly is as important as the query logic.

Inspect the physical plan before submitting large jobs:

```python
result.explain(mode="formatted")   # shows the full physical plan with estimated row counts
```

---

## Partitions, Parallelism, and the Relationship Between Them

The number of partitions in a DataFrame controls the parallelism of any transformation that operates without a shuffle (a **narrow** transformation: `filter`, `map`, `withColumn`). Each partition runs on one core.

```python
# How many partitions does this DataFrame have?
df = spark.read.parquet("s3://bucket/events/")
print(df.rdd.getNumPartitions())   # depends on the number of Parquet files / HDFS blocks

# Coalesce (reduce) partitions without a shuffle — faster, data stays local
df_small = df.filter("status = 'error'").coalesce(10)

# Repartition (increase or decrease) partitions WITH a shuffle — needed before a join
df_keyed = df.repartition(200, "customer_id")
```

### Default shuffle partition count

`spark.sql.shuffle.partitions` (default: 200) controls the number of partitions after any operation that requires a shuffle. 200 is wrong for almost all jobs:

- **Small dataset:** 200 partitions means 200 tiny tasks. Each task has overhead (JVM thread scheduling, serialization, shuffle read). For a 10 GB dataset, 20–40 partitions is usually better.
- **Large dataset:** 200 partitions means 200 potentially very large partitions. A 5 TB shuffle into 200 partitions gives 25 GB per task — likely to spill to disk and OOM.

The rule of thumb: target **100–500 MB per partition after a shuffle**. Measure and tune.

```python
# Adaptive Query Execution (AQE, Spark 3.0+) — the default-on fix
spark.conf.set("spark.sql.adaptive.enabled", "true")
spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "true")
# AQE coalesces shuffle partitions at runtime based on actual data sizes
# This largely eliminates the need to pre-tune shuffle.partitions
```

AQE is the single most impactful Spark 3 config if you are on an older job or disabled it.

---

## Shuffles — The Expensive Part

A **shuffle** is a full network exchange of data between executors: every executor sends some portion of its data to every other executor, based on the partitioning key. Shuffles are unavoidable for `groupBy`, `join`, `distinct`, `repartition`, and `orderBy`.

```
Before shuffle (groupBy customer_id):

Executor 1: rows for customer 1, 5, 9, 3, 7 ...
Executor 2: rows for customer 2, 4, 8, 1, 6 ...
Executor 3: rows for customer 3, 7, 2, 4, 5 ...

After shuffle (each executor owns one partition of customer_ids):

Executor 1: ALL rows for customers 1, 4, 7, 10 ...
Executor 2: ALL rows for customers 2, 5, 8, 11 ...
Executor 3: ALL rows for customers 3, 6, 9, 12 ...
```

The shuffle writes intermediate data to disk on each executor (the **shuffle write** phase), then each executor reads its assigned data from all other executors over the network (the **shuffle read** phase). Both are expensive.

### Minimizing shuffle cost

**1. Filter before joining.** The most common optimization:

```python
# Bad: join first (join is N*M rows), then filter
result = large_df.join(other_large_df, "id").filter("status = 'active'")

# Good: filter both sides first, then join (dramatically smaller shuffle)
result = large_df.filter("status = 'active'").join(
    other_large_df.filter("status = 'active'"), "id"
)
```

Catalyst usually does this automatically (predicate pushdown), but on complex multi-step pipelines with UDFs it cannot always prove the filter is safe to push. Verify with `explain()`.

**2. Broadcast join.** If one side of the join is small (fits in executor memory), broadcast it to all executors and avoid the shuffle entirely:

```python
from pyspark.sql.functions import broadcast

result = large_df.join(broadcast(small_lookup_df), "region_code")
# Spark sends small_lookup_df to every executor; large_df never moves
```

`spark.sql.autoBroadcastJoinThreshold` (default: 10 MB) controls when Spark does this automatically. Raise it for larger dimension tables:

```python
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", str(100 * 1024 * 1024))  # 100 MB
```

**3. Co-partition related datasets.** If you frequently join datasets on the same key, repartition and cache them once so the join requires no shuffle:

```python
orders_keyed = orders.repartition(200, "customer_id").cache()
events_keyed = events.repartition(200, "customer_id").cache()
# Multiple joins on customer_id now reuse the same partition layout — no re-shuffle
```

---

## Data Skew — The Silent Job Killer

**Data skew** is the condition where some partitions have dramatically more data than others. The job runs at the speed of the slowest partition (one or a few "stragglers"), while all other executors sit idle waiting for them.

```
Partition sizes after groupBy (skewed):

Partition 0:   100K rows  (done in 2s)
Partition 1:    80K rows  (done in 2s)
Partition 2:  5,000K rows (done in 120s)  ← straggler: all other executors idle
Partition 3:    90K rows  (done in 2s)

Total wall time: 120s, but useful work: 10s
```

### Detecting skew

The Spark UI is the primary tool. In the **Stages** tab, look at the task duration distribution. If max task time is 10–100× the median, you have skew. Click into a straggler task and look at the shuffle read size — a skewed partition will show a disproportionately large shuffle read.

```python
# Programmatic skew detection: inspect partition sizes
from pyspark.sql.functions import spark_partition_id, count

df.groupBy(spark_partition_id()) \
  .agg(count("*").alias("rows")) \
  .orderBy("rows", ascending=False) \
  .show(20)
```

### Fixing skew

**1. AQE skew join optimization (Spark 3.0+):** automatically splits skewed partitions mid-join. Enable it:

```python
spark.conf.set("spark.sql.adaptive.skewJoin.enabled", "true")
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionFactor", "5")  # 5x median = skewed
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes", str(256 * 1024 * 1024))
```

**2. Salting for GroupBy aggregations.** If AQE is unavailable or insufficient:

```python
import random
from pyspark.sql import functions as F

SALT_BUCKETS = 20

# Step 1: add a random salt to spread the hot key across 20 partitions
df_salted = df.withColumn(
    "salted_key",
    F.concat(F.col("customer_id"), F.lit("_"), (F.rand() * SALT_BUCKETS).cast("int").cast("string"))
)

# Step 2: partial aggregate on the salted key (runs in parallel across 20 tasks)
partial = df_salted.groupBy("salted_key").agg(F.sum("amount").alias("partial_sum"))

# Step 3: final aggregate by original key (now balanced)
final = partial.withColumn("customer_id", F.split("salted_key", "_").getItem(0)) \
               .groupBy("customer_id") \
               .agg(F.sum("partial_sum").alias("total"))
```

Salting works for associative aggregations (SUM, COUNT, MAX). It does not work for non-associative operations like `COUNT DISTINCT` without additional logic.

---

## Lazy Evaluation — Plans, Transformations, and Actions

Spark uses **lazy evaluation**: calling `.filter()`, `.join()`, or `.groupBy()` on a DataFrame does not execute anything — it adds a step to the logical plan. Execution is deferred until you call an **action**.

| Type | Examples | Effect |
|------|---------|--------|
| Transformation (lazy) | `filter`, `select`, `join`, `groupBy`, `withColumn`, `repartition` | Adds to the DAG, no computation |
| Action | `write`, `show`, `count`, `collect`, `take`, `first`, `foreach` | Triggers the optimizer and executes the entire DAG |

**Why this matters operationally:**

```python
# This line doesn't fail even if the parquet files don't exist yet
df = spark.read.parquet("s3://bucket/nonexistent/")

# This line will also NOT fail — it's still just building a plan
filtered = df.filter("amount > 100")

# THIS fails — action triggers execution, files are read here
filtered.count()
```

The implication: you cannot detect a missing file, a schema mismatch, or a bad path until an action runs. Add an early `.printSchema()` or `df.limit(1).show()` at the start of complex pipelines to fail fast rather than 2 hours into a large job.

### Caching and persistence

When the same DataFrame is referenced in multiple downstream paths, Spark recomputes it from scratch each time by default. Use `.cache()` or `.persist()` to materialize it once:

```python
# Without cache: orders read from S3 twice
result_a = orders.filter("status = 'paid'").groupBy("region").count()
result_b = orders.filter("status = 'paid'").groupBy("product").count()

# With cache: orders read from S3 once, the filtered DataFrame is cached in memory
orders_paid = orders.filter("status = 'paid'").cache()
result_a = orders_paid.groupBy("region").count()
result_b = orders_paid.groupBy("product").count()
```

Cache only DataFrames you reuse multiple times. Caching consumes executor memory (and disk if you use `MEMORY_AND_DISK`), and a spurious cache evicts a cache that another stage needed, causing a silent recompute.

---

## Joins and the Small-Files Problem

### The four join strategies

| Strategy | When Spark chooses it | Cost |
|---------|----------------------|------|
| Broadcast hash join | One side ≤ `autoBroadcastJoinThreshold` | No shuffle; fast |
| Shuffle hash join | Moderate-sized tables; `preferSortMerge=false` | One shuffle + hash table in memory |
| Sort-merge join | Default for large tables | Two shuffles + sort |
| Cartesian join | No join condition (or `crossJoin`) | O(N*M); catastrophically expensive |

Force a hint when Spark chooses the wrong strategy:

```python
from pyspark.sql.functions import broadcast

# Force broadcast join
df1.join(broadcast(df2), "id")

# Force shuffle hash
df1.hint("SHUFFLE_HASH").join(df2, "id")
```

### The small-files problem

A common pathology in production: a Spark job writes thousands of tiny Parquet files to S3 (one per task, per partition key). Downstream jobs that read the output must open thousands of S3 object handles — slow metadata operations dominate runtime.

Root cause: too many output partitions relative to data volume, or a high-cardinality `partitionBy` column.

```python
# Bad: 200 shuffle partitions → 200 small files per date partition
df.repartition(200).write.partitionBy("date").parquet("s3://bucket/output/")

# Good: coalesce to a small number before writing
target_file_size_mb = 256
total_mb = df.count() * avg_row_bytes / (1024 * 1024)  # estimate
num_files = max(1, int(total_mb / target_file_size_mb))
df.coalesce(num_files).write.partitionBy("date").parquet("s3://bucket/output/")
```

Apache Iceberg and Delta Lake both solve this with automatic compaction and file size management. If you are using Iceberg, `OPTIMIZE` + `REWRITE DATA FILES` compacts small files without a full rewrite of the table.

---

## When Spark Beats a Single Box

Spark adds significant operational overhead (cluster management, serialization, shuffle I/O). Before reaching for it, apply this test:

- **Data fits in RAM of a large single machine?** Pandas, DuckDB, or polars will be faster and simpler. A 64 GB machine runs polars at ~10 GB/s scan speed.
- **Data fits on disk of a large single machine but not in RAM?** DuckDB with out-of-core mode, or Polars with lazy evaluation (LazyFrame), handles 100s of GB on a single node.
- **Data requires distributed I/O because it lives in many S3 files across a data lake?** Spark earns its cost here.
- **The job is inherently parallel across independent partitions with no cross-partition aggregation?** Any distributed compute will work; Spark is a fine choice.
- **The job involves complex multi-step transformations over TBs with skewed joins?** Spark + AQE is the right tool.

The common mistake: using Spark (or submitting to a managed cluster like Glue) for jobs that process 500 MB of data, because "it's data engineering." The 5-minute job startup overhead dominates a 30-second query. Use the simplest tool that handles your data scale.

---

## Debugging Batch Processing & Spark

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Job completes but one stage takes 10× longer than others | Data skew: one partition has most of the data | Check Spark UI stage task distribution; enable AQE skew join; apply salting for groupBy |
| `OutOfMemoryError: GC overhead limit exceeded` during shuffle | Shuffle partition too large: `shuffle.partitions=200` with a 5 TB dataset means 25 GB per task | Increase `shuffle.partitions`; enable AQE (`adaptive.enabled=true`); increase executor memory |
| `SparkException: Task failed N times` on the same partition | OOM during processing, not shuffle — task keeps crashing with the same data | Inspect the data in the failing partition; identify anomalously large rows or skewed keys; repartition to isolate |
| Job reads from S3 and is much slower than expected | Small-files problem: thousands of tiny files, metadata overhead dominates scan time | Compact source files before the job; use Iceberg `OPTIMIZE`; `spark.sql.files.minPartitionNum` to limit task explosion |
| `shuffle spill (disk)` high in Spark UI | Shuffle data doesn't fit in executor memory; writes to disk and re-reads | Increase executor memory; reduce `shuffle.partitions`; enable AQE; broadcast the smaller side of a join |
| `Caused by: java.io.FileNotFoundException: s3://...` at action time | Source path doesn't exist — schema mismatch, missing partition, or wrong date parameter | Add `df.limit(1).show()` early in the job to fail fast; validate input paths before the main computation |
| Dataset cached but Spark UI shows it being recomputed | Cache was evicted under memory pressure; another stage needed the memory | Check memory fraction (`spark.memory.fraction`); reduce the number of concurrently cached DataFrames; use `MEMORY_AND_DISK` persistence |

> **War story.** A nightly Spark job at SAP processed ~200 GB of usage events and typically finished in 18 minutes. One morning it ran for 4 hours before I killed it. The Spark UI showed 199 tasks finishing in under 30 seconds and 1 task running for 3+ hours. Classic skew. The straggler was processing a single customer's data — a large enterprise customer whose account had been merged with two subsidiary accounts that morning, tripling the row count under one `customer_id`. The `groupBy customer_id` step was pushing all their records into one partition. The fix: enabled AQE skew join (one config line — we were already on Spark 3.2 but had never turned it on). The next run: 21 minutes. The lesson: always have AQE on, and always monitor the Spark UI task distribution on the first few runs after data volume changes. Average job time is a useless metric when one task is the bottleneck.

---

## Checkpoint

You can move on when you can answer these without reference:

1. What is a shuffle in Spark? Name three operations that cause a shuffle.
2. Explain the difference between a narrow transformation and a wide transformation (shuffle boundary). Give two examples of each.
3. Your job has `spark.sql.shuffle.partitions=200` and processes 4 TB of data. What is the approximate task size, and what problem does this cause?
4. Describe two concrete ways to avoid or minimize a shuffle for a join between a large table and a small lookup table.
5. You see one straggler task taking 50× the median time in the Spark UI Stage view. What is the most likely cause, and what is your first diagnostic step?
6. Explain lazy evaluation: what does calling `.filter()` do, and when does actual I/O begin?
7. What is the small-files problem, what causes it, and how do you fix it at write time?
8. When is Spark the *wrong* tool? Describe a scenario where DuckDB or polars would be a better choice, and explain why.

➡ You have completed the module series. Head to the challenges to apply these concepts hands-on.
