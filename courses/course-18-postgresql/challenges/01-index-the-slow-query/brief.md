# Index the Slow Query

> **Prereq:** Docker must be running. The challenge uses a local `dojo-pg` container on port 55432.

An on-call alert fires at 2 AM: p99 latency on `GET /users/:id/orders` has climbed to 4.2 s. The service dashboard shows no spike in traffic, no memory pressure, and no change in the application code. The only thing that changed was a batch import last week that added 80 000 new order rows to the database.

You SSH into the box and pull the slow-query log:

```
duration: 3947 ms  statement: SELECT * FROM orders WHERE user_id = 7777
```

3.9 seconds. For a query that should take single-digit milliseconds. Something is wrong at the database layer.

## Context

`setup.sh` creates a `dojo-pg` Docker container (Postgres 16) and seeds an `orders` table with 100 000 rows across 10 000 users. It plants a starter SQL file in your work directory:

```
~/.kube-dojo-work/01-index-the-slow-query/
└── solution.sql     # your CREATE INDEX goes here
```

**Docker prereq:** Docker must be running before you execute setup.sh.

```bash
bash courses/course-18-postgresql/challenges/01-index-the-slow-query/setup.sh
```

## The Problem — Why Sequential Scans Happen

PostgreSQL's query planner is a cost-based optimizer. For every query it estimates the cost of several execution plans and picks the cheapest. Without an index the only option for `WHERE user_id = 7777` is a **sequential scan**: read every page of the heap from disk into `shared_buffers`, examine every row, discard the ones that don't match.

```
Sequential scan on orders (100 000 rows)
───────────────────────────────────────
 Page 0: rows 1–100   → check user_id for each
 Page 1: rows 101–200 → check user_id for each
 ...
 Page N: rows ...     → 10 matching rows found, ~99 990 wasted
```

The planner's cost model: `seq_page_cost` (default 1.0) × number of heap pages, plus `cpu_tuple_cost` (default 0.01) × number of rows examined. For 100 000 rows spread across ~444 8kB pages, the estimated cost is `444 × 1.0 + 100000 × 0.01 = 1444`. That translates directly to wall-clock time.

An **index scan** breaks that:

```
B-tree index on orders(user_id)
───────────────────────────────
 Root → internal node → leaf node with user_id=7777 pointers
 Follow 10 heap pointers → fetch only 10 rows
```

The planner estimates `index_page_cost × log(N) + cpu_index_tuple_cost × rows_found`. For 10 matching rows on a 100k-row table the estimated cost drops to roughly `5–20`. Two orders of magnitude cheaper.

The planner switches to an index scan **only when an index exists** on the column(s) referenced in the WHERE clause. Without an index, it has no alternative to the sequential scan regardless of the table size.

## Mission

Run `setup.sh`, then add a B-tree index on the column the query filters by.

After creating the index, run `ANALYZE orders;` inside psql — the planner uses per-column statistics cached by the last ANALYZE run. Without fresh stats the planner may not know the new index exists and still choose a seq scan.

**Exact conditions `verify.sh` checks:**

1. An entry in `pg_indexes` where `tablename = 'orders'` and `indexdef` contains `user_id`.
2. `EXPLAIN (FORMAT JSON) SELECT * FROM orders WHERE user_id = 7777` has at least one plan node with `"Node Type": "Index Scan"` (or `"Index Only Scan"` or `"Bitmap Index Scan"`). A `"Seq Scan"` root fails.

## Verify

```bash
bash courses/course-18-postgresql/challenges/01-index-the-slow-query/verify.sh
```

## Why This Matters

A missing index is the most common cause of accidental performance regressions in production databases. The pattern is predictable: small data during development → no index needed → table grows → query regresses. The fix is two SQL lines and an ANALYZE. The lesson is to check EXPLAIN before shipping any query that filters, joins, or sorts a large table.

At SAP (and everywhere else with long-lived OLTP tables): every WHERE clause column that appears in a high-frequency query should have either a dedicated index or be part of a composite index — unless the table is tiny or the column is so low-cardinality that the planner would skip the index anyway (e.g., a boolean column).
