# Solution — Tune the Plan

## Step 1: Read the bad plan

```sql
EXPLAIN SELECT count(*) FROM ch06.events WHERE event_type = 'ERROR';
```

Before any fixes, you'll see something like:

```
Aggregate  (cost=5416.01..5416.02 rows=1 width=8)
  ->  Seq Scan on events  (cost=0.00..5416.00 rows=1 width=0)
        Filter: (event_type = 'ERROR'::text)
```

Two problems are visible:

1. **Seq Scan on events** — the planner reads every row in the 200 000-row table.
2. **rows=1** — the planner estimates 1 matching row. The actual count is 100. This 100× mis-estimate means the planner's cost calculation was essentially noise; it chose seq scan not because it's right, but because it had no information to do better.

Why does the planner think rows=1? After `INSERT` without `ANALYZE`, `pg_class.reltuples = -1` (unknown). The planner falls back to a default selectivity of `1/200` for equality predicates, applied to an unknown table size, and lands on a nearly zero estimate.

Confirm the stale stats:

```sql
SELECT relname, reltuples, relpages
FROM pg_class
WHERE relname = 'events'
  AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'ch06');
```

`reltuples = -1` tells the whole story.

---

## Step 2: Fix the statistics — ANALYZE

```sql
ANALYZE ch06.events;
```

`ANALYZE` samples the table (up to 30 000 rows by default, set by `default_statistics_target`). It:

1. Counts rows, updates `pg_class.reltuples` to ~200 000.
2. Builds a most-common-values (MCV) list for each column: for `event_type`, it records that `INFO` appears with frequency ≈ 0.9995 and `ERROR` with frequency ≈ 0.0005.
3. Builds histograms for numeric columns.
4. Computes correlation between physical order and logical order.

After ANALYZE, read the planner's new understanding:

```sql
SELECT
    attname,
    n_distinct,
    most_common_vals,
    most_common_freqs
FROM pg_stats
WHERE schemaname = 'ch06'
  AND tablename  = 'events'
  AND attname    = 'event_type';
```

Expected output:

```
 attname    | n_distinct | most_common_vals  | most_common_freqs
------------+------------+-------------------+-------------------
 event_type |          2 | {INFO,ERROR}      | {0.9995,0.0005}
```

`most_common_freqs[2] = 0.0005` means: the planner now knows `ERROR` accounts for 0.05% of rows. On a 200 000-row table: 200 000 × 0.0005 = **100 rows** — exactly right.

Now re-run EXPLAIN:

```sql
EXPLAIN SELECT count(*) FROM ch06.events WHERE event_type = 'ERROR';
```

Output after ANALYZE but still no index:

```
Aggregate  (cost=5416.01..5416.02 rows=1 width=8)
  ->  Seq Scan on events  (cost=0.00..5416.00 rows=100 width=0)
        Filter: (event_type = 'ERROR'::text)
```

The row estimate is now correct (`rows=100`). But the plan is still a seq scan — because there is no index to use. The planner correctly identifies that 100 rows need to be returned, but must still scan the whole table to find them. We need to give it an access path.

---

## Step 3: Add the B-tree index

```sql
CREATE INDEX idx_events_event_type ON ch06.events(event_type);
```

**Why B-tree for this column?**

`event_type` has two distinct values with equality predicates (`= 'ERROR'`). B-tree indexes excel at equality and range queries on low-cardinality columns. GIN/GiST are for multi-valued types (arrays, JSONB, tsvector). Partial indexes can make this even smaller:

```sql
-- Alternative: partial index — only indexes ERROR rows (100 entries, not 200 000)
CREATE INDEX idx_events_error_only ON ch06.events(event_type)
    WHERE event_type = 'ERROR';
```

A partial index on a rare predicate is extremely efficient: it's 2000× smaller (100 entries vs 200 000), fits entirely in cache, and the planner prefers it for `WHERE event_type = 'ERROR'` queries. For the verifier, either a full or partial index passes.

---

## Step 4: Re-check the plan

```sql
EXPLAIN SELECT count(*) FROM ch06.events WHERE event_type = 'ERROR';
```

Expected output after ANALYZE + index:

```
Aggregate  (cost=5.44..5.45 rows=1 width=8)
  ->  Index Scan using idx_events_event_type on events  (cost=0.42..5.19 rows=100 width=0)
        Index Cond: ((event_type)::text = 'ERROR'::text)
```

Cost dropped from **5416** to **5.44** — roughly a 1 000× improvement in estimated cost. In practice, this translates directly to query time: instead of reading every page of a 200 000-row table, the planner walks the B-tree to find 100 matching entries and reads only those 100 heap tuples.

---

## Step 5: Verify correctness

```sql
SELECT count(*) FROM ch06.events WHERE event_type = 'ERROR';
-- → 100
```

---

## Why both ANALYZE and index are required

| State | Rows estimated | Plan | Problem |
|-------|----------------|------|---------|
| No stats, no index | 1 | Seq Scan | Wrong estimate AND no access path |
| ANALYZE only | 100 | Seq Scan | Correct estimate, no access path |
| Index only (no ANALYZE) | 1 | Seq Scan or index scan with wrong cost | Planner might not use index because it thinks table is tiny |
| ANALYZE + index | 100 | Index Scan | Correct estimate + correct access path = correct plan |

This is the canonical "production table just got large" failure mode. After any bulk load, always run `ANALYZE` before handing the table to application traffic.

---

## Going deeper: statistics target

For highly selective columns (like `event_type = 'ERROR'` at 0.05%), the default statistics target of 100 is usually fine. But for columns with unusual distributions, increase the target:

```sql
ALTER TABLE ch06.events ALTER COLUMN event_type SET STATISTICS 500;
ANALYZE ch06.events;
```

A higher target means more sample rows per column, a larger MCV list, and more precise frequency estimates. The tradeoff is slower ANALYZE and more memory in `pg_statistic`. For most columns, 100 is correct; increase only for columns where the planner's row estimates are systematically wrong even after ANALYZE.

---

## Run the verifier

```bash
bash courses/course-18-postgresql/challenges/06-tune-the-plan/verify.sh
```
