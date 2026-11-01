# Ingestion & Change Data Capture

> **Module 02 · Course 26** — Getting data into your pipeline is deceptively complex. The easy part is the first full load; the hard part is every subsequent load: detecting what changed, handling out-of-order updates, merging partial updates into existing rows, and not duplicating anything when your extractor retries. This module covers the full ingestion spectrum — from a simple incremental query to log-based CDC — plus the correctness guarantees each approach provides.

---

## Pull vs Push — Who Initiates the Transfer

The distinction matters because it determines who owns the retry, backpressure, and schema negotiation logic.

| Model | Mechanism | Who drives | Examples |
|-------|-----------|-----------|---------|
| **Pull** | Your pipeline queries the source on a schedule | Consumer (your pipeline) | `SELECT * FROM orders WHERE updated_at > ?`, REST API polling, S3 prefix scan |
| **Push** | The source emits events when data changes | Producer (the source) | Kafka, webhooks, Debezium streaming CDC, PostgreSQL logical replication slots |

**Pull tradeoffs:** simple to implement, no changes needed to the source, works over any query interface. The cost: you must poll frequently enough to not miss events, source load scales with poll frequency, and `updated_at`-based watermarks miss hard-deletes entirely (a deleted row has no `updated_at` to query).

**Push tradeoffs:** lower latency, captures deletes, no polling load. The cost: source must support it (binlog/WAL replication), the consumer must handle duplicate delivery (most push systems are at-least-once), and the source must retain log entries long enough for the consumer to catch up.

---

## Full Loads vs Incremental Loads

A **full load** extracts the entire source table every run. It is the simplest, most reliable ingestion pattern — and also the most expensive.

```sql
-- Full load: extract everything
SELECT * FROM orders;
```

An **incremental load** extracts only rows that changed since the last successful run.

```sql
-- Incremental load: high-watermark pattern
SELECT * FROM orders
WHERE updated_at > :last_watermark
ORDER BY updated_at;
```

### When full loads are actually correct

Full loads are not wrong — they are appropriate when:
- The source table is small enough that a full re-extract is cheaper than implementing incremental state.
- The source has no reliable change timestamp (some legacy systems don't have `updated_at`).
- You need to capture hard-deletes: a row that no longer appears in the full extract was deleted.
- The pipeline runs infrequently enough (daily/weekly) that load on the source is acceptable.

### The high-watermark pattern

Incremental loads require tracking **where you left off**. The most common mechanism is a watermark — a cursor stored by the pipeline, advanced after each successful batch.

```
Load 1: watermark = 1970-01-01  →  extract rows where updated_at > 1970-01-01
        (gets all rows, watermark advances to max(updated_at) = 2026-10-31 23:59:59)

Load 2: watermark = 2026-10-31 23:59:59  →  extract only new/updated rows
        (gets only what changed since last run)
```

**Critical**: the watermark must be persisted durably (in a metadata table, not in memory) so a pipeline restart picks up where it left off rather than re-extracting everything.

```sql
-- Watermark metadata table
CREATE TABLE pipeline_state (
    pipeline_id   TEXT PRIMARY KEY,
    watermark     TIMESTAMPTZ,
    last_run_at   TIMESTAMPTZ
);

-- Update after a successful batch
UPDATE pipeline_state
SET watermark = (SELECT MAX(updated_at) FROM orders_staging),
    last_run_at = NOW()
WHERE pipeline_id = 'orders_incremental';
```

---

## Change Data Capture (CDC) — Capturing Every Event

High-watermark queries have two fundamental blind spots:
1. **Hard deletes**: if a row is deleted, it has no `updated_at` — the query will never see it.
2. **Intermediate updates**: if a row is updated twice between poll intervals, only the final state is captured. The intermediate state is lost.

**CDC** solves both by reading directly from the database's internal change log instead of querying the application data.

### Log-based CDC (the right approach)

Relational databases write every change to a write-ahead log (WAL) or binary log (binlog) before applying it to the table. This log exists for crash recovery; CDC piggybacks on it.

```
                    ┌─────────────────────────────────────────┐
                    │       PostgreSQL (source)                │
                    │                                          │
  app writes ──▶   │  WAL (write-ahead log)                   │
                    │  [INSERT orders(id=1, …)]                │
                    │  [UPDATE orders SET status='paid' …]     │
                    │  [DELETE FROM orders WHERE id=3]         │
                    └──────────────┬──────────────────────────┘
                                   │ logical replication slot
                                   ▼
                    ┌──────────────────────────────────────────┐
                    │         Debezium (CDC connector)          │
                    │  reads WAL, emits structured events       │
                    │  {op: "u", before: {…}, after: {…}}      │
                    └──────────────┬───────────────────────────┘
                                   │ Kafka topic
                                   ▼
                    ┌──────────────────────────────────────────┐
                    │         Downstream consumers              │
                    │  data warehouse, search index, cache      │
                    └──────────────────────────────────────────┘
```

**Debezium event envelope:**

```json
{
  "op": "u",
  "ts_ms": 1730400000000,
  "before": { "id": 42, "status": "pending", "amount": 100 },
  "after":  { "id": 42, "status": "paid",    "amount": 100 }
}
```

`op` values: `c` (create/insert), `u` (update), `d` (delete), `r` (snapshot/read during initial sync).

The `before` image is critical for downstream systems that need to know what changed, not just the final state (e.g., "amount decreased" triggers a different downstream action than "amount increased").

### Query-based CDC (the fallback)

When you cannot access the WAL (SaaS databases, legacy systems without replication slots), you fall back to query-based CDC:

```sql
-- Capture inserts and updates via high watermark (works for most cases)
SELECT * FROM orders WHERE updated_at > :last_watermark;

-- Detect deletes by comparing source keyset to target keyset
SELECT id FROM orders                 -- source
EXCEPT
SELECT source_id FROM orders_mirror;  -- target keyset table
-- Rows in the result were deleted from source
```

The delete detection query is expensive (full table scan of both sides) and only practical for small-to-medium tables. For large tables with frequent deletes, log-based CDC is not optional.

---

## Upserts, Merges, and the Natural Key Contract

CDC events deliver a stream of inserts, updates, and deletes. Your target table must be able to apply these operations correctly. This requires a **natural key** — a business-level identifier that uniquely identifies a record across all versions.

### MERGE / UPSERT — the standard pattern

```sql
-- SQL MERGE (ANSI standard, supported in Snowflake, BigQuery, Spark SQL)
MERGE INTO dim_orders AS target
USING staging_orders AS source
  ON target.order_id = source.order_id
WHEN MATCHED AND source.op = 'd' THEN DELETE
WHEN MATCHED AND source.op IN ('u', 'r') THEN UPDATE SET
    target.status = source.after_status,
    target.updated_at = source.after_updated_at
WHEN NOT MATCHED AND source.op = 'c' THEN INSERT (order_id, status, created_at, updated_at)
    VALUES (source.after_order_id, source.after_status, source.after_created_at, source.after_updated_at);
```

### SCD Type 2 — Keeping History

If you need to preserve the full history of changes (not just the current state), use a **Slowly Changing Dimension Type 2** (SCD-2) pattern:

```sql
-- Instead of updating in place, insert a new version and close the old one
UPDATE dim_users
SET effective_to = NOW()
WHERE user_id = :id AND effective_to IS NULL;

INSERT INTO dim_users (user_id, email, plan, effective_from, effective_to)
VALUES (:id, :new_email, :new_plan, NOW(), NULL);
```

The `WHERE effective_to IS NULL` condition selects the current version. Historical queries use `WHERE effective_from <= :as_of AND (effective_to > :as_of OR effective_to IS NULL)`.

SCD-2 is the standard pattern for dimension tables in star schemas where you need to answer questions like "what plan was this user on when they placed this order?"

---

## Deduplication — Handling At-Least-Once Delivery

Almost every ingestion system delivers data at-least-once. A network retry, a Kafka consumer rebalance, or a Debezium reconnect can replay events that were already processed. Your silver-tier transform must deduplicate before surfacing data to consumers.

```python
# PySpark dedup: keep the latest version of each event, by natural key
from pyspark.sql import functions as F
from pyspark.sql.window import Window

w = Window.partitionBy("order_id").orderBy(F.desc("event_ts"))

deduped = (
    raw_df
    .withColumn("rn", F.row_number().over(w))
    .filter("rn = 1")
    .drop("rn")
)
```

This is a **deterministic dedup**: given the same input, you always get the same output. The key invariant is that `event_ts` (the source database timestamp, not the ingestion timestamp) is used for ordering — not your pipeline's processing time, which can vary across runs.

---

## Watermarks and Clock Skew

A watermark is your pipeline's claim about time: "I believe I have seen all events with `event_ts <= watermark`." The claim is almost always slightly wrong, because:

1. **Clock skew:** source servers' clocks differ from each other and from your pipeline's clock.
2. **Late-arriving data:** events generated at time T may not arrive in your pipeline until T + several minutes (network queues, producer batching, retry delays).
3. **Partitioned sources:** if events arrive from multiple Kafka partitions or database shards, the slowest partition can lag behind the others.

The fix is to set the watermark conservatively — typically `watermark = MAX(event_ts) - lag_budget`, where `lag_budget` is empirically determined from your P99 ingestion latency.

```python
# Flink-style watermark strategy (pseudocode)
# Tolerate events arriving up to 10 minutes late
watermark_strategy = WatermarkStrategy \
    .for_bounded_out_of_orderness(Duration.of_minutes(10)) \
    .with_timestamp_assigner(lambda event, _: event.event_ts_ms)
```

Events that arrive after the watermark has advanced past their `event_ts` are **late** and are either dropped or routed to a side output for separate reconciliation. The tradeoff: a wider lag budget means lower risk of missed events but higher latency in your output.

---

## Debugging Ingestion & CDC

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Row count in target slowly drifts below source | Deletes not captured: using high-watermark query which misses deletes | Add key-set delete detection or switch to log-based CDC; monitor `COUNT(*)` on source vs target daily |
| Duplicate rows in target after a pipeline restart | At-least-once re-delivery of CDC events, no dedup in silver layer | Enforce dedup on natural key in silver transform; add a unique index (or `ON CONFLICT DO NOTHING`) on the target |
| Some updates missing: final state correct but intermediate states lost | Poll interval too wide: two updates happened between polls | Switch to log-based CDC for tables with high update frequency; reduce poll interval as a short-term fix |
| Debezium connector falls behind, consumer lag grows, eventually offset expires | Kafka topic retention shorter than reprocessing window; connector paused during maintenance | Set Kafka retention on CDC topics to ≥7 days; monitor consumer lag with `kafka-consumer-groups.sh --describe`; set `max.poll.records` appropriately |
| Watermark stops advancing; new data not showing in analytics | Source clock skew or a stalled partition; the max `updated_at` seen is stuck because the slowest shard is lagging | Check `MAX(updated_at)` per source shard; fix the stalled shard; use `MIN(MAX(updated_at))` across shards as the safe watermark |
| Pipeline fails with "slot `debezium` does not exist" on reconnect | PostgreSQL replication slot was dropped (e.g., after RDS failover or manual cleanup) | Re-create the slot and restart Debezium snapshot; ensure `max_replication_slots` is set high enough; add monitoring on `pg_replication_slots` |
| Watermark jumps forward too aggressively; late events silently dropped | Lag budget too narrow; events from a slow producer arrive after the window closes | Widen the watermark lag budget and measure late arrival rate; route late events to a reconciliation topic rather than dropping them |

> **War story.** On a usage-metering pipeline, we used a high-watermark query on the `updated_at` column to capture order status changes. For three months everything looked fine. Then the fraud team flagged a discrepancy: ~0.3% of completed orders were missing from the analytics table. Investigation revealed a race condition: the application updated `updated_at` *before* committing the status change in the same transaction (a bug in the application ORM). The CDC query ran in the brief window after `updated_at` was written but before the status commit, captured the row as "pending", then never saw the status change because the `updated_at` was now in the past relative to the watermark. The fix was two-fold: fix the ORM transaction ordering, and switch that table to Debezium log-based CDC to capture every commit, not just the `updated_at` cursor. The lesson: high-watermark CDC is not truly correct under concurrent writes; only log-based CDC captures the committed state.

---

## Checkpoint

You can move on when you can answer these without reference:

1. Name two things a high-watermark incremental query cannot capture, and explain why.
2. What is a Debezium event envelope? What does `op: "d"` deliver and why does it matter?
3. Explain the dedup pattern using `ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...)` — what does `rn = 1` select?
4. What is a PostgreSQL logical replication slot, and what happens if it is not consumed for a long time?
5. Why must the watermark use `event_ts` (source timestamp) rather than the pipeline's processing time?
6. Describe when SCD-2 is appropriate vs a simple UPSERT, and state the query predicate that selects the current version.
7. Your analytics row count is consistently 0.2% below the source. Walk through your diagnosis steps.
8. What is the minimum Kafka topic retention you should set on CDC topics and why?

➡ Next up: **Streaming with Kafka** — topics, partitions, consumer groups, delivery semantics, windowing.
