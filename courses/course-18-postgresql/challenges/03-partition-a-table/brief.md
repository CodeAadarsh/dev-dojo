# Partition a Table by Month

> **Prereq:** Docker must be running. The challenge uses a local `dojo-pg` container on port 55432.

Six months ago the events table was 2 GB and queries ran in under 50 ms. Today it is 180 GB and the weekly VACUUM takes 11 hours, nightly archival jobs time out, and `DELETE FROM events WHERE created_at < NOW() - interval '90 days'` now locks the table for 40 minutes and disrupts production traffic.

The postmortem verdict: the table should have been partitioned from day one. Your task is to fix it now.

## Context

`setup.sh` creates a `dojo-pg` container (Postgres 16) and seeds a plain, non-partitioned `events` table with rows spread across January, February, and March 2024. It plants a migration stub in your work directory:

```
~/.kube-dojo-work/03-partition-a-table/
└── migrate.sql    # migration stub — fill it in
```

**Docker prereq:** Docker must be running before you execute setup.sh.

```bash
bash courses/course-18-postgresql/challenges/03-partition-a-table/setup.sh
```

## Why Partition?

Declarative partitioning (Postgres 10+) turns one monolithic table into a tree of child tables managed transparently by the planner. For a time-series events table the benefits compound:

**Partition pruning.** The planner inspects the partition bounds at query planning time. `WHERE created_at >= '2024-02-01' AND created_at < '2024-03-01'` will access only the February partition — the January and March partitions are pruned from the plan entirely, as if they don't exist.

**Faster bulk DELETE / DROP.** Archiving three months of old data becomes `DROP TABLE events_2023_10` — a metadata-only operation that finishes in milliseconds instead of a row-by-row DELETE that holds locks for minutes.

**Smaller indexes.** Each partition has its own index covering only its rows. An index on a 10 GB monthly partition is an order of magnitude cheaper to maintain than the same index on a 180 GB monolith.

**Reduced VACUUM pressure.** VACUUM processes dead tuples per-partition. A table that only receives writes in the current-month partition means older partitions rarely need vacuuming at all.

## The Constraint — You Cannot ALTER In-Place

PostgreSQL has no `ALTER TABLE events PARTITION BY RANGE (created_at)`. Once a table is created without partitioning, the only way to add partitioning is to create a new partitioned table and migrate the data. The standard pattern:

```
1. ALTER TABLE events RENAME TO events_old;
2. CREATE TABLE events (...) PARTITION BY RANGE (created_at);
3. CREATE TABLE events_YYYY_MM PARTITION OF events
       FOR VALUES FROM ('YYYY-MM-01') TO ('next-month');
   -- repeat for each month you need
4. INSERT INTO events SELECT * FROM events_old;
5. DROP TABLE events_old;  -- optional, keep it if you want a rollback path
```

Note: a partitioned parent table cannot have a `PRIMARY KEY` unless the partition key column is included in the key. For the `id BIGSERIAL PRIMARY KEY` column to work on the parent, `id` must be part of any unique constraint — but that is a separate topic. For this challenge the migration stub drops the `PRIMARY KEY` on the parent for simplicity (each child partition still gets a `NOT NULL` identity column).

## Mission

Complete `~/.kube-dojo-work/03-partition-a-table/migrate.sql` so that:

1. `events` becomes a table declared with `PARTITION BY RANGE (created_at)`.
2. At least **two** monthly child partitions exist (e.g., `events_2024_01` and `events_2024_02`) each declared with `FOR VALUES FROM ('YYYY-MM-01') TO ('next-month-01')`.
3. Inserts for January 2024 dates route to a child partition, not the parent.

Apply when ready:

```bash
docker exec -i dojo-pg psql -U postgres -d dojo < \
  ~/.kube-dojo-work/03-partition-a-table/migrate.sql
```

**Exact conditions `verify.sh` checks:**

1. `events` is listed in `pg_partitioned_table` (it is a partitioned table, not a plain heap).
2. `pg_inherits` shows at least 2 child relations with `events` as the parent.
3. `INSERT INTO events ... created_at = '2024-01-15'` succeeds AND `tableoid::regclass` for that row is NOT `'events'` (it landed in a child partition).

## Verify

```bash
bash courses/course-18-postgresql/challenges/03-partition-a-table/verify.sh
```

## Why This Matters

Partitioning is a architectural decision that must happen before the table is large — retrofitting it at 180 GB requires a migration window with downtime or a careful online migration (using triggers + background copy, similar to `pg_repack`). The production version of this migration also needs to handle foreign keys from other tables, triggers, row-level security policies, and publication membership for logical replication — none of which transfer automatically to the new partitioned table.

The canonical approach for zero-downtime migrations on live tables at scale is to:
1. Create the new partitioned table alongside the old one.
2. Install a trigger on the old table that dual-writes inserts and updates to the new table.
3. Backfill historical data in small batches using background workers.
4. Atomically swap the tables (rename + rename in one transaction) once backfill is complete.
5. Remove the trigger and the old table.

For this challenge the table is small and downtime is acceptable, so the direct approach is sufficient.
