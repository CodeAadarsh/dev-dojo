# Tune the Plan

On-call. 02:30. PagerDuty fires: *"Error rate spike — 503s from the monitoring service."* You SSH in and trace the slow queries. Grafana shows one query at 4 000 ms average — it was 12 ms yesterday. The query:

```sql
SELECT count(*) FROM events WHERE event_type = 'ERROR';
```

Nothing changed in the application. But overnight, a data migration job loaded 200 000 rows into `events`. The table grew by 200×, and the query planner never got the memo — it's still working from statistics that say the table has "about" 1 000 rows. Without accurate row counts, without an index, the planner scans the entire 200 000-row table to count 100 ERROR rows. That's a 2 000× waste.

Your job: diagnose the plan, explain why it's wrong, and fix it so the planner makes a good decision.

---

## How the PostgreSQL query planner works

The planner is a cost-based optimizer. It generates candidate plans (seq scan, index scan, hash join, nested loop, etc.) and picks the one with the lowest estimated cost. Cost is measured in abstract "page reads", tunable via `seq_page_cost`, `random_page_cost`, `cpu_tuple_cost`, etc.

The planner needs two inputs to estimate cost:

1. **Row counts and selectivity** — "how many rows does this predicate match?" This comes from `pg_statistic`, populated by `ANALYZE`.
2. **Available access paths** — "what indexes exist on the referenced tables?" This comes from `pg_class` + `pg_index`.

If either input is wrong, the plan is wrong. In this challenge, both are missing:

```
┌────────────────────────────────────────────────────────────────┐
│  Table: ch06.events                                            │
│                                                                │
│  Reality:  200 000 rows, 100 ERROR rows (0.05% selectivity)   │
│  Planner:  reltuples = -1 (unknown — ANALYZE never ran)        │
│            no index on event_type                              │
│                                                                │
│  Decision: Seq Scan  (only path available; cost estimate wrong)│
└────────────────────────────────────────────────────────────────┘
```

### Reading EXPLAIN output

`EXPLAIN` shows the plan tree. Each node has:

```
Node Type on table  (cost=startup..total rows=estimated width=bytes)
```

`EXPLAIN ANALYZE` additionally shows:

```
  (actual time=startup..total rows=actual loops=N)
```

The gap between `rows=estimated` and `rows=actual` is the **row mis-estimate** — the most important signal for diagnosing a bad plan. A 1000× mis-estimate means the planner's cost calculation was meaningless.

```
-- Bad plan (no stats, no index):
Seq Scan on events  (cost=0.00..5416.00 rows=1 width=...)
  Filter: (event_type = 'ERROR')

-- The planner estimated 1 row. Actual is 100.
-- It chose seq scan because it thought the result was tiny
-- (and tiny result + seq scan can be optimal — but the estimate was wrong).

-- After ANALYZE + index:
Aggregate  (cost=5.44..5.45 rows=1 width=8)
  ->  Index Scan using idx_events_event_type on events  (cost=0.42..5.19 rows=100 width=0)
        Index Cond: ((event_type)::text = 'ERROR'::text)
```

### Why stale statistics are dangerous

PostgreSQL uses statistics at plan-compile time, not run time. A plan compiled from stale stats will stay wrong until the query is re-parsed or the plan cache is evicted. In a connection pool that reuses prepared statements, a bad plan can persist for hours even after you run ANALYZE — only new connections or explicit `DEALLOCATE` clears it.

### ANALYZE internals

`ANALYZE` samples the table (default: 30 000 rows, configurable via `default_statistics_target`). It builds histograms, most-common-values lists, and correlation estimates, storing them in `pg_statistic`. For a column like `event_type` with two values (`ERROR`, `INFO`):

```sql
-- See the most-common-values for event_type after ANALYZE:
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

After ANALYZE, `most_common_freqs` for `ERROR` would show ≈ 0.0005 (100 / 200 000), which the planner uses to estimate `100 × 200 000 = 100` matching rows — matching reality.

### The index

Even with correct statistics, a seq scan on 200 000 rows for 100 matching tuples is expensive. A B-tree index on `event_type` lets the planner use an **Index Scan**: walk the B-tree to find all leaf entries where `event_type = 'ERROR'` (an O(log n) lookup), then fetch only those 100 heap pages. For 0.05% selectivity, the index scan is roughly 2 000× cheaper than the seq scan.

---

## Prerequisites

Docker must be running. `setup.sh` starts (or reuses) a `dojo-pg` container:

```bash
bash courses/course-18-postgresql/challenges/06-tune-the-plan/setup.sh
```

Connect with:

```bash
psql -h 127.0.0.1 -p 55432 -U postgres -d dojo
# password: dojo
```

---

## Mission

Setup has created `ch06.events` with:
- **200 000 rows**: 100 where `event_type = 'ERROR'`, 199 900 where `event_type = 'INFO'`
- **No index** on `event_type`
- **autovacuum disabled** — statistics are stale (reltuples reflects only the create-time defaults)

Your tasks:

1. **Read the bad plan.** Run `EXPLAIN SELECT count(*) FROM ch06.events WHERE event_type = 'ERROR';` and identify the plan node (Seq Scan) and the row mis-estimate.

2. **Fix the statistics.** Run `ANALYZE ch06.events;` to collect fresh statistics.

3. **Add the index.** Create a B-tree index on `event_type`.

4. **Re-check the plan.** Run `EXPLAIN` again. It should now show an `Index Scan` (or `Bitmap Index Scan`) instead of `Seq Scan on events`.

5. **Confirm correctness.** The query `SELECT count(*) FROM ch06.events WHERE event_type = 'ERROR';` must return exactly **100**.

### What `verify.sh` checks (exactly)

| Check | Condition | Failure message |
|-------|-----------|-----------------|
| Index on event_type | Row in `pg_indexes` for `ch06.events` with `event_type` in `indexdef` | "no index found on ch06.events.event_type" |
| Plan is efficient | `EXPLAIN` does NOT contain "Seq Scan on events" | "plan still shows a Seq Scan — run ANALYZE and ensure the index exists" |
| Correct result | `COUNT(*)` returns 100 | "query returned N rows, expected 100" |

All three must pass.

---

## Starter SQL

Your work directory `~/.kube-dojo-work/06-tune-the-plan/` contains `fix_the_plan.sql`.

---

## Verify

```bash
bash courses/course-18-postgresql/challenges/06-tune-the-plan/verify.sh
```
