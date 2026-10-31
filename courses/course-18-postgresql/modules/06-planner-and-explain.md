# The Planner & EXPLAIN ANALYZE

> **Module 06 · Course 18** — The query planner is the part of Postgres that decides *how* to answer your SQL. It chooses scan types, join algorithms, and execution order — and it gets this right the vast majority of the time. When it doesn't, the resulting plan can be 100–10,000x slower than the optimal one. This module teaches you to read `EXPLAIN ANALYZE` output fluently, understand the cost model that drives plan decisions, and diagnose and fix the four most common planning failures.

Knowing SQL well enough to write correct queries is table stakes. Knowing the planner well enough to fix slow queries is what separates an intermediate from an expert. This module is the bridge.

---

## The cost model in one page

The planner is a **cost-based optimiser (CBO)**. It enumerates candidate plans, assigns each a numeric cost (in arbitrary "cost units" proportional to wall time), and picks the cheapest one. The cost model has three inputs:

1. **Statistics** — estimates of row counts, value distributions, and correlations, stored in `pg_statistic` and surfaced through `pg_stats`.
2. **Configuration parameters** — cost weights that calibrate the model to your hardware.
3. **Catalog metadata** — table sizes in pages (`pg_class.relpages`), index sizes, etc.

### Cost parameters (set in `postgresql.conf`)

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `seq_page_cost` | 1.0 | Cost to read one sequential heap page |
| `random_page_cost` | 4.0 | Cost to read one random heap page (via index) |
| `cpu_tuple_cost` | 0.01 | Cost to process one tuple |
| `cpu_index_tuple_cost` | 0.005 | Cost to process one index entry |
| `cpu_operator_cost` | 0.0025 | Cost to apply one operator |
| `effective_cache_size` | 4 GB | Planner's estimate of OS+Postgres cache (does not allocate memory) |

The ratio `random_page_cost / seq_page_cost = 4.0` means random I/O is assumed 4x more expensive than sequential. On fast NVMe SSDs, a ratio of 1.1–1.5 is more accurate. Leaving it at 4.0 on a modern SSD-backed database causes the planner to undervalue index scans — it will prefer sequential scans more than it should.

```sql
-- For a cloud SSD instance (AWS gp3, GCP pd-ssd):
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_cache_size = '75% of total RAM';
SELECT pg_reload_conf();
```

### How the planner estimates row counts

The planner needs to know: "how many rows will this predicate return?" It answers using **column statistics** collected by `ANALYZE`:

```
pg_statistic (raw stats) ←— surfaced as pg_stats (human-readable) ←— populated by ANALYZE
```

Key statistics per column:

| `pg_stats` column | What it stores |
|-------------------|----------------|
| `null_frac` | Fraction of NULLs |
| `n_distinct` | Number of distinct values (negative = fraction of total rows) |
| `most_common_vals` / `most_common_freqs` | Up to `default_statistics_target` (100) most frequent values and their frequencies |
| `histogram_bounds` | Percentile boundaries for the remaining values |
| `correlation` | Correlation between physical order and logical order (1.0 = perfectly correlated, useful for BRIN/IOS decisions) |

For a predicate `WHERE status = 'active'`, the planner checks `most_common_vals`. If 'active' is in the MCV list, it uses the stored frequency directly. If not, it uses `(1 - sum(most_common_freqs)) / (n_distinct - count(MCVs))` — a uniform distribution assumption for non-MCV values.

For a range predicate `WHERE amount BETWEEN 100 AND 500`, it uses the histogram bounds to estimate what fraction of the bucket boundaries fall within the range.

### The statistics target

`default_statistics_target = 100` means ANALYZE collects up to 100 MCVs and 100 histogram buckets per column. For high-cardinality columns with skewed distributions (like `account_id` on a multi-tenant system), 100 buckets is often too few.

```sql
-- Increase statistics for a specific high-cardinality column:
ALTER TABLE orders ALTER COLUMN account_id SET STATISTICS 500;
ANALYZE orders;
-- Now check the improved histogram:
SELECT histogram_bounds FROM pg_stats WHERE tablename = 'orders' AND attname = 'account_id';
```

A higher statistics target slows down `ANALYZE` (samples more rows) and uses more memory in `pg_statistic`, but results in more accurate row estimates — which can flip a bad plan to a good one.

---

## Scan types

The planner chooses among four scan types for a single table. Understanding when each applies is essential for reading EXPLAIN output.

### Sequential scan (Seq Scan)

Reads every page of the heap in order, processes every row. Cost = `seq_page_cost * pages + cpu_tuple_cost * rows`. No index required. The fastest choice when:
- The predicate is not selective (returns > ~15–20 % of rows).
- The table is small enough to fit in memory.
- The column has no index, or the index is bloated.

```
Seq Scan on orders  (cost=0.00..2840.00 rows=50000 width=48)
                     Filter: (status = 'pending')
                     Rows Removed by Filter: 150000
```

`Rows Removed by Filter` is the heap row wastage — rows read but not returned. High values here means the planner should have used an index.

### Index Scan

Traverses the B-tree (or other index), then fetches heap pages in TID order (which is random order on the heap). Cost includes both index traversal and random heap I/O. Preferred when selectivity is high (few rows returned).

```
Index Scan using idx_orders_account on orders  (cost=0.43..16.45 rows=12 width=48)
  Index Cond: (account_id = 42)
```

### Bitmap Scan (Bitmap Index Scan + Bitmap Heap Scan)

A two-phase approach: first pass builds an in-memory bitmap of all matching TIDs; second pass sorts TIDs by block number and reads heap pages in sequential order to minimise random I/O.

```
Bitmap Heap Scan on orders  (cost=112.50..1240.30 rows=4500 width=48)
  Recheck Cond: (account_id = 42)
  ->  Bitmap Index Scan on idx_orders_account  (cost=0.00..111.38 rows=4500 width=0)
        Index Cond: (account_id = 42)
```

Bitmap scans shine when the query returns thousands of rows spread across many heap pages — too many for an index scan (too much random I/O) but too selective for a seq scan. The bitmap also enables AND/OR of multiple indexes:

```sql
-- Can combine two partial indexes using a bitmap AND:
EXPLAIN SELECT * FROM orders
WHERE account_id = 42 AND status = 'pending';
-- ->  BitmapAnd
--       ->  Bitmap Index Scan on idx_orders_account
--       ->  Bitmap Index Scan on idx_orders_status
```

`Recheck Cond` appears when the bitmap overflows `work_mem` and falls back to a lossy bitmap (one bit per *page*, not per row). The lossy bitmap still narrows the read to fewer pages, but requires re-evaluating the predicate on every row in each page.

### Index-Only Scan

Discussed in Module 05. No heap page reads when all projected columns are in the index and the visibility map bit is set.

```
Index Only Scan using idx_users_email_status on users  (cost=0.43..4.45 rows=1 width=20)
  Index Cond: (email = 'alice@example.com')
  Heap Fetches: 0      ← ideal: no heap I/O
```

`Heap Fetches > 0` after `VACUUM` indicates the visibility map is not fully populated — run `VACUUM` to set the VM bits.

---

## Join algorithms

When two tables are joined, Postgres chooses among three algorithms. The choice depends on the join condition, available indexes, relative sizes, and available `work_mem`.

### Nested Loop

```
Nested Loop  (cost=0.43..88.50 rows=12 width=72)
  ->  Index Scan on accounts  (cost=0.29..8.31 rows=1 width=24)
        Index Cond: (id = 42)
  ->  Index Scan on orders  (cost=0.43..8.01 rows=12 width=48)
        Index Cond: (account_id = accounts.id)
```

For each row from the outer table, execute the inner scan. Cost: `outer_rows * inner_scan_cost`. Fast when:
- The outer scan returns very few rows (1–hundreds).
- The inner scan uses an index (O(log n) per inner lookup).
- The inner result set is small and likely cached after the first few iterations.

Nested loop is the default choice for selective joins. It becomes catastrophic when the outer table returns thousands of rows and the inner scan is a seq scan — cost becomes O(N * M) and the planner typically avoids this unless statistics are badly wrong.

### Hash Join

```
Hash Join  (cost=1155.00..4890.50 rows=50000 width=72)
  Hash Cond: (orders.account_id = accounts.id)
  ->  Seq Scan on orders  (cost=0.00..2840.00 rows=200000 width=48)
  ->  Hash  (cost=640.00..640.00 rows=41200 width=24)
        Buckets: 65536  Batches: 1  Memory Usage: 3MB
        ->  Seq Scan on accounts  (cost=0.00..640.00 rows=41200 width=24)
```

Builds a hash table from the smaller table (inner), then probes the hash for each row of the larger table (outer). Cost: `O(build) + O(probe)` — linear in both tables. Fast when:
- Both tables are large and there is no useful index for the join.
- Available `work_mem` fits the hash table (if not, multi-batch hash join spills to disk — watch `Batches: N` where N > 1).

`Batches: 1` means the hash table fit in memory. `Batches: 4` means four passes over the data — significantly slower, often fixable by increasing `work_mem` for the session.

### Merge Join

```
Merge Join  (cost=12450.00..16000.00 rows=50000 width=72)
  Merge Cond: (orders.account_id = accounts.id)
  ->  Sort  (cost=6200.00..7400.00 rows=200000 width=48)
        Sort Key: orders.account_id
        ->  Seq Scan on orders
  ->  Sort  (cost=2100.00..2350.00 rows=41200 width=24)
        Sort Key: accounts.id
        ->  Seq Scan on accounts
```

Both inputs must be sorted on the join key. If sorted indexes exist on both sides, no explicit sort step is needed and a merge join is extremely efficient — it's a single O(N+M) pass. Without pre-sorted inputs, the sort cost dominates and a hash join is usually preferred.

---

## Reading EXPLAIN ANALYZE output — the full picture

`EXPLAIN` shows the *estimated* plan. `EXPLAIN ANALYZE` actually executes the query and shows *actual* vs *estimated* row counts and execution time.

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT u.email, count(o.id)
FROM   users u
JOIN   orders o ON o.account_id = u.id
WHERE  u.created_at > NOW() - INTERVAL '30 days'
GROUP  BY u.email
ORDER  BY count(o.id) DESC
LIMIT  10;
```

A typical output:
```
Limit  (cost=9540.23..9540.25 rows=10 width=40)
       (actual time=124.3..124.3 rows=10 loops=1)
  ->  Sort  (cost=9540.23..9565.23 rows=10000 width=40)
            (actual time=124.2..124.3 rows=10 loops=1)
        Sort Key: (count(o.id)) DESC
        Sort Method: top-N heapsort  Memory: 26kB
        ->  HashAggregate  (cost=8990.00..9090.00 rows=10000 width=40)
                           (actual time=122.8..123.5 rows=9800 loops=1)
              Group Key: u.email
              Batches: 1  Memory Usage: 3MB
              ->  Hash Join  (cost=420.50..8740.00 rows=50000 width=16)
                             (actual time=3.1..108.4 rows=52000 loops=1)
                    Hash Cond: (o.account_id = u.id)
                    Buffers: shared hit=4820 read=640
                    ->  Seq Scan on orders  ...
                    ->  Hash  ...
                          Buckets: 16384  Batches: 1  Memory: 820kB
                          ->  Index Scan using idx_users_created on users ...
                                Index Cond: (created_at > ...)
                                Rows Removed by Index Recheck: 0
```

### What to look for

**1. Estimated vs actual rows (the most important signal):**
```
(cost=420.50..8740.00 rows=50000 ...)   ← planner estimated 50,000
(actual time=3.1..108.4   rows=52000 ...)  ← actual was 52,000  (good: close)
```
When estimated rows are orders of magnitude off, the plan may be wrong. The planner chose plan X assuming 500 rows; it actually got 50,000 — a nested-loop that was O(n) becomes O(n²).

**2. `loops` > 1 — multiply the actual time:**
```
(actual time=0.01..0.12 rows=3 loops=4820)
```
The `actual time` shown is per loop. Total time = `0.12 ms * 4820 = 578 ms`. This is a common trap: a node looks fast but has a huge loop count (it's the inner side of a nested loop executing 4820 times).

**3. `Buffers: shared hit=N read=M`:**
- `shared hit` = pages served from `shared_buffers` (fast, no I/O)
- `read` = pages that required a disk read (slow)
- `dirtied` = pages modified in shared_buffers
- A high `read` count on a frequently-run query indicates the working set doesn't fit in `shared_buffers` — consider tuning `shared_buffers` or caching upstream.

**4. Sort method and memory:**
```
Sort Method: external merge  Disk: 14400kB
```
An external merge sort means the sort spilled to disk — `work_mem` is too low for this sort. Increase `work_mem` for the session and re-run.

**5. `Rows Removed by Filter` vs `Index Cond`:**
If an index condition removes few rows but a filter removes many, an index on the filter column may help, or the index condition may have a type mismatch preventing effective filtering.

---

## `pg_statistic` and controlling statistics

```sql
-- Human-readable statistics per column:
SELECT attname, n_distinct, correlation, most_common_vals, most_common_freqs
FROM   pg_stats
WHERE  tablename = 'orders'
ORDER  BY attname;
```

**`n_distinct` interpretation:**
- Positive integer → exact distinct count (used when the table is small).
- Negative fraction → fraction of rows that are distinct (e.g. -0.95 means 95 % of rows are unique, high cardinality).
- `-1` → every row is distinct (primary keys, UUIDs).

**`correlation` interpretation:**
- Close to 1.0: physical row order matches logical value order. Index scans are cheap (heap pages accessed in order).
- Close to 0: random physical order. Index scan has high random I/O cost. Planner may prefer seq scan.
- Close to -1.0: reverse correlation. Index scan descending is cheap.

If statistics are stale, run `ANALYZE tablename` (or `ANALYZE` for all tables). The autovacuum worker runs ANALYZE automatically after a table crosses `autovacuum_analyze_threshold + autovacuum_analyze_scale_factor * reltuples` row changes — by default 50 rows + 20 % of table size.

For very large tables (hundreds of millions of rows), the default 20 % scale factor means millions of rows must change before auto-ANALYZE triggers. Consider lowering the scale factor on large tables:

```sql
ALTER TABLE events SET (
    autovacuum_analyze_scale_factor = 0.01,   -- trigger after 1% change
    autovacuum_analyze_threshold = 1000
);
```

---

## Fixing bad plans — the toolbox

### Bad plan 1: row count mis-estimate

**Symptom:** EXPLAIN ANALYZE shows estimated rows wildly different from actual rows (10x or more).

**Causes and fixes:**

```sql
-- 1. Stale statistics:
ANALYZE orders;

-- 2. Statistics target too low for high-cardinality column:
ALTER TABLE orders ALTER COLUMN account_id SET STATISTICS 500;
ANALYZE orders;

-- 3. Multi-column correlation (condition on A AND B, but stats are per-column):
-- Extended statistics capture column correlations:
CREATE STATISTICS stat_orders_account_status ON account_id, status FROM orders;
ANALYZE orders;
-- Check that it's populated:
SELECT stxname, stxkind, stxdndistinct, stxdependencies
FROM pg_statistic_ext
JOIN pg_statistic_ext_data ON oid = stxoid
WHERE stxname = 'stat_orders_account_status';
```

### Bad plan 2: sequential scan on a large table

**Symptom:** Seq Scan on a million-row table, slow query, an index exists.

**Diagnosis:**
```sql
-- Is the index actually being used anywhere?
SELECT idx_scan FROM pg_stat_user_indexes WHERE indexrelname = 'idx_orders_account_id';

-- Force the index to compare costs:
SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE account_id = 42;
RESET enable_seqscan;
```

**Common causes:**
1. **random_page_cost too high** for SSD: set to 1.1.
2. **effective_cache_size too low**: set to 75 % of RAM; this tells the planner how much OS page cache is available, raising the effective hit rate assumed for index I/O.
3. **Type mismatch**: column is `integer`, predicate uses a string literal, implicit cast prevents index use.
4. **Function applied to column**: `WHERE lower(email) = 'alice@...'` on an index on `email` — create an expression index.

### Bad plan 3: nested-loop blowup

**Symptom:** a query that joins a large outer set to a large inner set uses Nested Loop; `actual loops=N` is in the thousands; query takes minutes.

**Diagnosis:**
```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT ...
FROM large_table l
JOIN other_large_table o ON l.fk = o.id
WHERE l.some_flag = true;
-- Look for:
-- Nested Loop  (actual loops=250000)
--   -> Seq Scan on other_large_table (actual rows=1 loops=250000)
```

If `loops` is high and the inner scan is a seq scan or an unindexed lookup, you have a nested-loop blowup.

**Fix options:**
1. **Add an index on the inner join column** — converts inner seq scan to index scan, reducing inner cost from O(M) to O(log M).
2. **Disable nested loop for the session** (diagnostic only — not for production):
   ```sql
   SET enable_nestloop = off;
   EXPLAIN ...;
   RESET enable_nestloop;
   ```
3. **Increase statistics** so the planner sees the outer table returns many rows and chooses hash join instead.
4. **Rewrite the query** — sometimes a CTE or a subquery that materialises the outer result gives the planner better cardinality information.

---

## Debugging: row mis-estimates

```sql
-- Show per-column stats that feed the estimate:
SELECT attname, null_frac, n_distinct, correlation,
       array_length(most_common_vals::text[], 1) AS mcv_count
FROM   pg_stats
WHERE  tablename = 'orders';

-- Check if a value you're filtering on is in the MCV list:
SELECT most_common_vals, most_common_freqs
FROM   pg_stats
WHERE  tablename = 'orders' AND attname = 'status';
-- If 'pending' is not in most_common_vals and the table is heavily skewed,
-- the planner will use the uniform distribution estimate — which may be way off.

-- Add extended statistics for correlated columns:
CREATE STATISTICS stat_orders_status_region ON status, region FROM orders;
ANALYZE orders;
```

---

## Debugging: seq scan on a big table despite an index

```sql
-- Step 1: verify the index exists and is valid
SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'orders';

-- Step 2: check index usage counters (has it ever been used?)
SELECT indexrelname, idx_scan, idx_tup_read, idx_tup_fetch
FROM   pg_stat_user_indexes WHERE relname = 'orders';

-- Step 3: check correlation (low correlation → random I/O → planner prefers seq scan)
SELECT correlation FROM pg_stats WHERE tablename = 'orders' AND attname = 'created_at';
-- If correlation is 0.02 (nearly random), an index on created_at will be slow anyway.
-- Consider CLUSTER + VACUUM to physically reorder the heap, or use a BRIN index.

-- Step 4: adjust cost parameters for SSD:
SHOW random_page_cost;   -- if 4.0 on SSD, lower it
ALTER SYSTEM SET random_page_cost = 1.1;
SELECT pg_reload_conf();
```

---

## Debugging: nested-loop blowup

```sql
-- Find the worst-performing queries involving joins:
SELECT query, calls, mean_exec_time, total_exec_time
FROM   pg_stat_statements
WHERE  query ILIKE '%join%'
ORDER  BY mean_exec_time DESC
LIMIT  5;

-- For the worst offender, get the plan:
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
<paste the query here>;

-- Check actual_loops on the inner node:
-- If actual_loops > 10000 on a seq scan, you have a blowup.

-- Confirm the inner join column is indexed:
SELECT indexname, indexdef FROM pg_indexes
WHERE  tablename = 'other_large_table'
AND    indexdef ILIKE '%fk_column%';
```

---

## Checkpoint

You are ready for the planner challenges when you can, without looking anything up:

1. Explain what `seq_page_cost`, `random_page_cost`, and `effective_cache_size` control in the cost model, and state the recommended values for an NVMe SSD instance.
2. Given a `pg_stats` row with `n_distinct = -0.02`, state what this means and what kind of index selectivity to expect for an equality predicate.
3. Read the following EXPLAIN ANALYZE node and state the total actual time and whether work_mem is a bottleneck: `(actual time=0.01..0.05 rows=4 loops=12000)`, `Sort Method: external merge Disk: 8000kB`.
4. A query joins `orders` (1 M rows) to `accounts` (50 K rows) using a Nested Loop with `actual loops=50000`. What is wrong, what index is missing, and what would the plan look like after fixing it?
5. Describe two mechanisms that cause estimated rows to diverge from actual rows, and the SQL to fix each.
6. A Bitmap Heap Scan shows `Batches: 8` in the Hash node. What does this indicate and how do you fix it without a schema change?
7. Explain the difference between `Buffers: shared hit=9800 read=200` and `shared hit=200 read=9800` for a hot query, and what you would do about the second case.
8. When would you deliberately create extended statistics (`CREATE STATISTICS`), and what kinds of correlation does it capture that per-column statistics cannot?

➡ Next up: **Module 07 — Operations & Tuning** — VACUUM/autovacuum, connection pooling, partitioning, and the configuration knobs that govern Postgres production behaviour.
