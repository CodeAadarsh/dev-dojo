# VACUUM the Bloat

A Jira ticket lands in your queue at 09:15: *"Reporting dashboard is timing out. Table `events` was fast last week."* You pull up Datadog and see the query time creeping up over three days — not a spike, a slow grind. The last deployment? Zero. The last schema change? Also zero. You dig into `pg_stat_user_tables` and find `n_dead_tup = 67 442`. The table has been hammered by an overnight ETL job that does full-table UPDATE sweeps, and autovacuum was quietly throttled to protect OLTP latency. The heap has turned into a graveyard of dead tuples that every sequential scan has to wade through.

This is one of the most common yet least-understood Postgres performance failure modes in production. Your job: diagnose the bloat, understand why it exists, and clean it up.

---

## MVCC and dead tuples — why bloat happens

PostgreSQL implements concurrency control via **MVCC** (Multi-Version Concurrency Control). The headline consequence for storage:

> **An UPDATE is physically an INSERT of a new version plus a deletion marker on the old one.**

There is no in-place overwrite. Every UPDATE to a row produces:
1. A new **heap tuple** (the updated version) written somewhere in the table's pages.
2. The old heap tuple is marked dead with `xmax = <committing transaction id>`.

A `DELETE` similarly marks the existing tuple dead without freeing space immediately.

```
BEFORE UPDATE id=42:                    AFTER UPDATE id=42:

Page 7                                  Page 7
┌──────────────────────────────────┐    ┌──────────────────────────────────┐
│ [id=42, status='pending'] xmax=0 │    │ [id=42, status='pending'] xmax=T │  ← dead
│                                  │    │ [id=42, status='active']  xmax=0 │  ← live (new version)
└──────────────────────────────────┘    └──────────────────────────────────┘
```

Dead tuples stay in the file. Sequential scans must visit them and check their `xmax` to determine visibility. A table with 15 000 live rows and 65 000 dead rows is nearly 5× larger than it needs to be, and every scan pays for all 80 000 tuple slot reads.

### Why doesn't the OS see the bloat?

`pg_relation_size()` measures file size on disk — and that number stays **large** even after VACUUM. VACUUM frees dead tuple slots for re-use by future inserts, but it does **not** truncate the file (unless the freed pages happen to be at the physical tail, which is rare). The file only shrinks with `VACUUM FULL`, which rewrites the entire table.

```
                 n_dead_tup   file size
────────────────────────────────────────
after heavy churn   ~65 000   large
after VACUUM           ~0     same large (but space is re-usable)
after VACUUM FULL      ~0     shrinks    (whole table rewritten)
```

### autovacuum — the maintenance daemon

PostgreSQL ships `autovacuum`, a background daemon that fires VACUUM automatically when a table's dead tuple ratio crosses a threshold:

```
autovacuum triggers when:
  n_dead_tup > autovacuum_vacuum_threshold          (default 50)
            + autovacuum_vacuum_scale_factor * reltuples  (default 0.2)

For a 15 000-row table:  50 + 0.2 × 15 000 = 3 050 dead tuples
```

Why was it not helping here? In this challenge, `autovacuum_enabled = false` has been set on the table — a common production "optimisation" applied to high-churn tables to reduce lock contention and I/O, with the side-effect that manual maintenance is now required. The brief teaches you what to do when autovacuum is off or has fallen behind.

---

## Prerequisites

Docker must be running. `setup.sh` starts (or reuses) a `dojo-pg` container:

```bash
bash courses/course-18-postgresql/challenges/04-vacuum-the-bloat/setup.sh
```

Connect with:

```bash
psql -h 127.0.0.1 -p 55432 -U postgres -d dojo
# password: dojo
```

Or via Docker:

```bash
docker exec -it dojo-pg psql -U postgres -d dojo
```

---

## Mission

Setup has planted the following state in the `dojo` database:

- Schema `ch04`, table `ch04.events` — seeded with **20 000 rows** then pounded with three full-table `UPDATE` sweeps and a `DELETE` of 5 000 rows.
- `autovacuum_enabled = false` on the table, so the dead tuples have accumulated.
- Expected state: **~15 000 live tuples, ~65 000 dead tuples**.

Your tasks:

1. **Diagnose** the bloat by querying `pg_stat_user_tables`. Confirm `n_dead_tup` is large and `last_vacuum IS NULL`.
2. **Run the right VACUUM** to reclaim the dead space. Do **not** drop, truncate, or rebuild the table from scratch — the verifier checks that live rows are still present.
3. **Re-check** — after VACUUM, `n_dead_tup` should be near zero.

### What `verify.sh` checks (exactly)

The verifier runs three assertions:

| Check | Condition | Failure message |
|-------|-----------|-----------------|
| Table survives | `ch04.events` exists in `information_schema.tables` | "did you accidentally DROP or TRUNCATE it?" |
| Live rows remain | `n_live_tup > 1000` in `pg_stat_user_tables` | "table appears empty — do not TRUNCATE, just VACUUM" |
| Dead tuples cleared | `n_dead_tup < 100` in `pg_stat_user_tables` | "still too many dead tuples — run VACUUM and retry" |

All three must pass to receive the flag.

---

## VACUUM variants — pick the right tool

| Command | What it does | Lock held | File shrinks? | When to use |
|---------|-------------|-----------|---------------|-------------|
| `VACUUM tbl` | Marks dead tuples as reusable | ShareUpdateExclusiveLock (table stays live) | No | Routine; safe in production |
| `VACUUM ANALYZE tbl` | VACUUM + updates planner statistics | Same | No | Best default: one command, two benefits |
| `VACUUM FULL tbl` | Rewrites entire table into new file | AccessExclusiveLock (table locked for writes) | Yes | Last resort — blocks all access |
| `VACUUM VERBOSE tbl` | VACUUM + prints per-block progress | Same | No | Diagnosing where bloat is |

> **Production rule of thumb:** never reach for `VACUUM FULL` as a first response. It holds an exclusive lock — on a high-traffic table that means downtime. Regular `VACUUM ANALYZE` is the right routine maintenance command. If you truly need the file to shrink (disk alarm), consider `pg_repack` as a zero-downtime alternative.

---

## Diagnosing before you fix

Always read the patient before operating. The starter SQL at `~/.kube-dojo-work/04-vacuum-the-bloat/diagnose_and_vacuum.sql` contains these diagnostic queries — run them before and after:

```sql
-- Current bloat state
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

```sql
-- Physical file size (won't shrink after plain VACUUM)
SELECT
    pg_size_pretty(pg_total_relation_size('ch04.events')) AS total_size,
    pg_size_pretty(pg_relation_size('ch04.events'))       AS heap_size;
```

---

## Verify

```bash
bash courses/course-18-postgresql/challenges/04-vacuum-the-bloat/verify.sh
```
