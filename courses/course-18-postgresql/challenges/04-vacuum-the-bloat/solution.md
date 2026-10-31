# Solution — VACUUM the Bloat

## Step 1: Diagnose the bloat

Connect to the database and read `pg_stat_user_tables`:

```sql
SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    round(100.0 * n_dead_tup
          / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
WHERE schemaname = 'ch04';
```

Expected output before cleanup:

```
  relname  | n_live_tup | n_dead_tup | dead_pct | last_vacuum | last_autovacuum
-----------+------------+------------+----------+-------------+-----------------
 events    |      15000 |      65000 |     81.2 |             |
```

`last_vacuum` and `last_autovacuum` are both NULL — the table has never been vacuumed. `dead_pct = 81%` means 81% of the heap is dead weight that every scan must wade through.

Physical size confirms the bloat:

```sql
SELECT
    pg_size_pretty(pg_total_relation_size('ch04.events')) AS total_size,
    pg_size_pretty(pg_relation_size('ch04.events'))       AS heap_size;
```

You'll see a size disproportionate to 15 000 rows — because the heap still holds 80 000 tuple slots (15 000 live + 65 000 dead).

---

## Step 2: Run VACUUM ANALYZE

```sql
VACUUM ANALYZE ch04.events;
```

**Why `VACUUM ANALYZE` and not just `VACUUM`?**

- `VACUUM` alone marks dead tuple slots as reusable and resets `n_dead_tup`.
- Adding `ANALYZE` makes PostgreSQL sample the table and update `pg_statistic`, which feeds the query planner. After heavy churn, the planner's row-count estimates are stale — without ANALYZE, a newly vacuumed table can still produce bad query plans because the planner thinks the distribution hasn't changed.
- Doing both in one statement is the standard maintenance pattern.

**Why not `VACUUM FULL`?**

`VACUUM FULL` rewrites the entire table into a new file and then swaps the old file out. During the rewrite, it holds an `AccessExclusiveLock` — the table is completely blocked for reads and writes. On a live production system that's downtime. In most cases you don't need the disk space back immediately; you just need the dead tuples to stop degrading scan performance. Plain `VACUUM` achieves that without any lock beyond `ShareUpdateExclusiveLock` (which doesn't block normal reads or writes).

The only time `VACUUM FULL` (or the better alternative, `pg_repack`) is justified is when you need to reclaim disk space urgently on a disk that's nearly full.

---

## Step 3: Verify the result

```sql
SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    last_vacuum
FROM pg_stat_user_tables
WHERE schemaname = 'ch04';
```

Expected output after cleanup:

```
  relname | n_live_tup | n_dead_tup |          last_vacuum
----------+------------+------------+-------------------------------
 events   |      15000 |          0 | 2024-xx-xx xx:xx:xx.xxxxxx+00
```

`n_dead_tup = 0` and `last_vacuum` is now set.

Note that `pg_relation_size('ch04.events')` still returns the same large number — the file was not truncated. The freed pages are internally marked as available for future inserts. Only `VACUUM FULL` (or `CLUSTER` or `pg_repack`) physically shrinks the file.

---

## Going deeper: autovacuum tuning

In production, the best fix for this scenario is not manual VACUUM — it's tuning autovacuum to fire more aggressively on high-churn tables:

```sql
ALTER TABLE ch04.events SET (
    autovacuum_enabled               = true,
    autovacuum_vacuum_scale_factor   = 0.01,   -- trigger at 1% dead tuples (default 20%)
    autovacuum_analyze_scale_factor  = 0.005,  -- analyze at 0.5% changes
    autovacuum_vacuum_cost_delay     = 2        -- milliseconds; lower = more aggressive I/O
);
```

And monitor it:

```sql
SELECT
    schemaname,
    relname,
    n_dead_tup,
    last_autovacuum,
    autovacuum_count
FROM pg_stat_user_tables
WHERE relname = 'events';
```

For tables with millions of rows, even the default `scale_factor = 0.2` means autovacuum doesn't fire until 200 000 dead tuples have accumulated. Lowering the scale factor for high-churn tables is one of the highest-leverage Postgres tuning decisions at scale.

---

## Run the verifier

```bash
bash courses/course-18-postgresql/challenges/04-vacuum-the-bloat/verify.sh
```
