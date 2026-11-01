# Data Engineering Foundations

> **Module 01 · Course 26** — Before you land in streaming pipelines or cluster tuning, you need the foundational vocabulary tight. This module covers the conceptual layer that every architecture decision in data engineering traces back to: the OLTP/OLAP split, ETL vs ELT, batch vs streaming, the modern data stack, and the two properties that determine whether your pipeline is correct — idempotency and the medallion tiering contract.

You're an SDE, not a data analyst, so this is fast on motivation and slow on the parts that get production pipelines killed silently: non-idempotent loads, late-arriving data, and schema drift at the worst possible moment.

---

## OLTP vs OLAP — Why the Split Exists

The two system classes exist because read vs write access patterns are fundamentally in tension once you're past toy scale.

| Property | OLTP | OLAP |
|----------|------|------|
| Primary workload | Short, high-frequency reads and writes (transactions) | Long scans over large datasets (analytics) |
| Data granularity | Individual rows | Aggregations of millions of rows |
| Schema style | Normalized (3NF) — minimize redundancy | Denormalized / star / snowflake — minimize joins at query time |
| Typical engines | Postgres, MySQL, Aurora | BigQuery, Redshift, Snowflake, ClickHouse |
| Optimization axis | Low-latency write path, row storage | Scan throughput, columnar storage, vectorized execution |
| Concurrent users | Thousands of app transactions | Dozens of analysts running expensive queries |

Columnar storage is the key insight behind OLAP: if a query touches only 3 columns out of 100, a row-oriented store reads 100 columns from disk anyway. A columnar store reads exactly 3. At petabyte scale this is the difference between a $300 query and a $30 query, and between 5 seconds and 45 seconds of wall time.

> **Row vs column at memory level:** row stores lay out `[row1_col1, row1_col2, ..., row2_col1, ...]`; columnar stores lay out `[col1_row1, col1_row2, ..., col2_row1, ...]`. Compression ratios on columnar data are dramatically better because adjacent values in a column are usually similar (e.g., a `country` column with mostly `"DE"` and `"US"` compresses to almost nothing). Parquet, ORC, and Arrow all exploit this.

The **critical corollary for SDE work:** never run analytics queries directly on your OLTP database. It is not just a performance problem — long-running analytical scans hold row locks or consume connection pool slots, stalling your application's writes. This is why the ETL/ELT pipeline exists at all.

---

## ETL vs ELT — Where the Transformation Lives

Both patterns move data from source systems to an analytical target. The difference is *when* you transform.

```
ETL (Extract → Transform → Load)
                                      ┌─────────────────┐
  OLTP DB  ──extract──▶  staging  ──transform──▶  Data Warehouse
  App logs                (RAM/disk)                (already clean)
  APIs                   transform here,
                         only load what's needed

ELT (Extract → Load → Transform)
                                                     ┌──────────────────────┐
  OLTP DB  ──extract──▶  raw landing zone  ──load──▶  Data Warehouse (raw)
  App logs                                             └──────┐
                                                          transform here
                                                          (dbt, Spark SQL)
                                                              │
                                                          analytics tables
```

**ETL era (pre-2015):** warehouse storage was expensive; you transformed to minimize what you stored. The transformation logic lived in heavyweight tools (Informatica, SSIS) that were painful to version-control.

**ELT era (now):** cloud warehouses like BigQuery and Snowflake have cheap, abundant storage and massive compute. Load *everything* raw first (cheap), then transform inside the warehouse using SQL (fast, versionable with dbt). You can re-run the transformation without re-extracting from the source.

The practical rule: **ELT is the default** in new greenfield systems unless you have a regulatory/PII reason to sanitize before landing, or the transformation requires logic that SQL genuinely cannot express.

---

## Batch vs Streaming — The Latency Dial

These are not binary categories — they are extremes on a latency continuum.

| Dimension | Batch | Micro-batch | Streaming |
|-----------|-------|-------------|-----------|
| Trigger | Scheduled (hourly, daily) | Small time windows (1–5 min) | Every event as it arrives |
| Latency | Minutes to hours | Seconds to minutes | Sub-second to seconds |
| Throughput | Very high (optimize for bulk I/O) | High | Moderate (stateful overhead) |
| Complexity | Low | Medium | High (state mgmt, ordering, exactly-once) |
| Use cases | Nightly ETL, monthly billing | Dashboard refresh, alerting | Fraud detection, live recommendations |
| Examples | Spark batch jobs, AWS Glue | Spark Structured Streaming, Flink micro-batch | Flink, Kafka Streams, Apache Beam |

**The common misconception:** streaming is not always better. A pipeline that produces hourly aggregates for a BI dashboard has no business being a streaming job. Streaming infrastructure carries real operational cost — partitioning, consumer group management, state store evictions, exactly-once semantics — that batch jobs avoid entirely. Choose streaming when business latency requirements genuinely demand it; don't reach for it to look sophisticated.

**Micro-batch is the compromise:** Spark Structured Streaming and Flink's windowed processing both buffer events into time-bounded windows before processing. The stateful logic is identical to true streaming, but throughput is higher and the exactly-once problem is easier to reason about.

---

## The Modern Data Stack

The phrase "modern data stack" describes the layered set of composable SaaS/open-source tools that replaced monolithic ETL suites. Each layer has a clear responsibility.

```
                          ┌─────────────────────────────────────────┐
                          │             Serve / Consume              │
                          │   BI tools (Metabase, Looker, Superset)  │
                          │   ML feature stores, APIs, notebooks     │
                          └─────────────────┬───────────────────────┘
                                            │ read
                          ┌─────────────────▼───────────────────────┐
                          │             Transform                     │
                          │   dbt (SQL transforms, lineage, tests)   │
                          │   Spark SQL, Apache Beam                 │
                          └─────────────────┬───────────────────────┘
                                            │ write
                          ┌─────────────────▼───────────────────────┐
                          │          Store (Data Lake / Warehouse)    │
                          │   Raw zone → bronze → silver → gold      │
                          │   S3 + Parquet/Iceberg, BigQuery, etc.   │
                          └─────────────────┬───────────────────────┘
                                            │ loads into
                          ┌─────────────────▼───────────────────────┐
                          │               Ingest                      │
                          │   Fivetran / Airbyte (connectors)        │
                          │   Debezium CDC, Kafka, custom extractors │
                          └─────────────────┬───────────────────────┘
                                            │ reads from
                          ┌─────────────────▼───────────────────────┐
                          │            Sources                        │
                          │   OLTP DBs, SaaS APIs, event streams     │
                          │   app logs, clickstream, third-party     │
                          └─────────────────────────────────────────┘
```

The insight is **composability**: each layer can be swapped independently. Replace Airbyte with a custom Debezium setup without touching your dbt transforms. Add Apache Iceberg as your table format without changing ingestion. This is what makes the modern stack genuinely different from the "ETL platform does everything" era.

---

## Idempotency & Reprocessing — The Correctness Constraint

An operation is **idempotent** if running it once produces the same result as running it N times. In data engineering, a pipeline is idempotent if re-running it over the same input range produces the same output — no duplicates, no missing rows, no double-counts.

Idempotency is not optional. Pipelines fail. Backfills happen. SLAs require reprocessing a date range after a bug fix. If your load job is not idempotent, every replay risks corrupting your analytics tables.

### Three patterns for achieving idempotency

**1. Truncate-and-reload (simplest, not always feasible)**

```sql
-- Before every batch run:
DELETE FROM analytics.daily_orders WHERE date = '2026-10-31';
INSERT INTO analytics.daily_orders
SELECT date, SUM(amount) FROM orders WHERE date = '2026-10-31' GROUP BY date;
```

Safe if the partition is small. Scales poorly because delete + insert is expensive on large tables and blocks readers.

**2. UPSERT / MERGE (transactional idempotency)**

```sql
-- Postgres example with a natural key
INSERT INTO dim_users (user_id, email, updated_at)
VALUES (42, 'new@example.com', NOW())
ON CONFLICT (user_id)
DO UPDATE SET email = EXCLUDED.email, updated_at = EXCLUDED.updated_at;
```

This requires a **natural key** — something in the data itself that uniquely identifies the row. Without it, you cannot distinguish "new row" from "redelivered row."

**3. Partition overwrite (the Spark/Iceberg approach)**

```python
# Overwrite a specific partition atomically — idiomatic in Spark
df.write \
    .partitionBy("event_date") \
    .mode("overwrite") \
    .option("partitionOverwriteMode", "dynamic") \
    .parquet("s3://bucket/events/")
```

`dynamic` partition overwrite: only partitions present in `df` are replaced. Other partitions are untouched. This is the safest large-scale pattern and is what most Iceberg + Spark pipelines use.

### Reprocessing design contract

Design every pipeline with the expectation that it will be re-run over the same time window. That means:

- **Parameterize the time range** — never use `NOW()` or `CURRENT_DATE` in the load query; pass the date as a pipeline argument.
- **Source data must be immutable or versioned** — if the source can change, snapshot it at extract time.
- **Downstream must support re-ingestion** — either through UPSERT semantics or partition overwrite.

---

## The Medallion Architecture

The medallion pattern names three tiers of data quality in a lakehouse, making the state of any dataset explicit to every consumer.

```
┌───────────┐   ──raw append──▶   ┌────────────┐   ──clean/dedupe──▶   ┌──────────┐
│  Sources  │                     │   Bronze   │                        │  Silver  │
│ (OLTP,    │                     │ raw, landed│                        │ validated│
│  streams) │                     │ immutable  │                        │ deduped  │
└───────────┘                     └────────────┘                        └────┬─────┘
                                                                             │ ──aggregate/enrich──▶
                                                                       ┌─────▼──────┐
                                                                       │    Gold    │
                                                                       │ business   │
                                                                       │ aggregates │
                                                                       └────────────┘
```

| Tier | Contract | Who reads | What you do |
|------|----------|-----------|-------------|
| Bronze | Raw, as-delivered, append-only. Never modified after landing. | Reprocessing jobs, debugging | Load without transformation. Schema evolution allowed. |
| Silver | Cleaned, deduplicated, schema-enforced, PII masked. | Engineering, data science | Validate types, dedupe on natural key, handle nulls, apply retention rules. |
| Gold | Business aggregates, pre-joined fact tables, SLA-grade data. | BI tools, dashboards, ML feature stores | Compute aggregations, join dimension tables, enforce business logic. |

**The contract that makes reprocessing safe:** bronze is immutable and complete. If your silver or gold logic has a bug, you can re-run the silver transform from bronze without re-extracting from the source. This separation of raw landing from computed output is the single biggest reliability win in lakehouse design.

---

## Debugging Data Engineering Foundations

Production data pipelines fail silently more often than they error loudly. The three failure modes below each cause corrupted analytics that pass smoke tests — the worst kind of bug.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Row counts are ~2× expected after a backfill | Non-idempotent INSERT: the pipeline ran twice and appended both times instead of overwriting | Switch to UPSERT/MERGE or partition overwrite; add a pre-load DELETE on the target partition |
| Aggregates jump on days that "already loaded" | Reprocessing ran without cleaning the target partition first; old + new rows are both present | Wrap every load in a transaction: delete target partition then insert, or use `INSERT OVERWRITE` |
| New source column causes pipeline to fail with schema mismatch | Schema-on-read (Parquet/Avro) discovered a new column at transform time; no schema evolution policy | Enforce schema registry (Avro/Confluent Schema Registry) at ingest; use `mergeSchema` in Spark for controlled evolution; add schema contracts in dbt |
| OLTP query times spike after analytics job starts | Analytics query running against OLTP replica; long scan holding locks or consuming all connections | Move analytics to dedicated OLAP system; enforce read replica read-only user for extract jobs only; add query timeout |
| Late-arriving events missing from daily aggregates | Watermark too tight; events arriving after the window closed are silently dropped | Widen the watermark; use re-stateable processing (Flink late data sink) or a T+1 reconciliation job |
| "Looks fine" aggregate is subtly wrong — counts off by a few hundred | Duplicate events in source (at-least-once delivery); no dedup before aggregation | Add dedup on natural key in the silver tier; use COUNT(DISTINCT id) as a correctness probe |

> **War story.** At SAP we had a usage-metering pipeline writing hourly aggregates to BigQuery. After a bug fix we backfilled 30 days of data. The pipeline re-ran cleanly — no errors, row counts matched expectations. Two days later the finance team flagged that monthly totals were doubled. The root cause: the aggregation job used `INSERT` instead of `INSERT OVERWRITE`, and both the original run and the backfill run were present in the table. BigQuery doesn't enforce primary keys, so there were no conflicts — just silent doubling. The fix was a pre-flight `DELETE FROM table WHERE date BETWEEN backfill_start AND backfill_end` wrapped in a transaction before every insert. We added an idempotency test to CI: run the pipeline twice over the same date range, assert row count is identical both times.

---

## Checkpoint

You're ready to move on when you can answer these without looking anything up:

1. Explain why a columnar store like Parquet is faster for analytical queries than a row store, in terms of I/O.
2. When would you choose ETL over ELT, and what is the main advantage of ELT in a modern cloud warehouse?
3. Give a concrete business requirement that justifies streaming latency over batch — and one where it doesn't.
4. Describe the three medallion tiers and state the contract each tier makes to its consumers.
5. Write a SQL snippet showing an idempotent upsert using `ON CONFLICT` — identify what property of the data makes it safe.
6. Your daily aggregation job ran twice. Without looking at the code, name two diagnostic queries you would run on the target table to detect duplication.
7. Explain why parameterizing the time range in a pipeline (instead of `NOW()`) is necessary for correct reprocessing.
8. A new column appears in the source Parquet files and your transform job crashes. Walk through the failure mode and how the medallion architecture contains the blast radius.

➡ Next up: **Ingestion & Change Data Capture** — pull vs push, incremental loads, watermarks, and Debezium-style CDC.
