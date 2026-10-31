# Operations & Tuning

> **Module 07 · Course 18** — Running Postgres in production means more than getting queries right. It means understanding the maintenance machinery that keeps the storage engine healthy (VACUUM), the connection management that keeps the process count from killing you (PgBouncer), the partitioning that keeps large tables from becoming a liability, and the handful of configuration parameters that determine whether your instance handles 500 QPS smoothly or OOM-panics at 200. This module covers all of it — internals first, practical tuning second.

The stakes here are higher than in the planner module. A bad query plan costs you latency on one query. A misconfigured `work_mem` or a lagging autovacuum can silently degrade an entire cluster, or — in the case of transaction ID wraparound — **shut it down completely**.

---

## VACUUM — the storage reclaimer

### Why Postgres needs VACUUM at all

Postgres implements MVCC (Multi-Version Concurrency Control) by keeping multiple versions of each row. When a row is updated or deleted, the old version is **not removed** — it is marked as dead with a `xmax` (transaction-max) stamp. A concurrent transaction might still need to see the old version, so physical deletion cannot happen immediately.

```
Heap page before vacuum:
  ┌───────────────────────────────────────────────────────────────────┐
  │ tuple (xmin=1000, xmax=0,    data='active')   ← live             │
  │ tuple (xmin=990,  xmax=1001, data='old value')← dead (updated)   │
  │ tuple (xmin=995,  xmax=1003, data='deleted')  ← dead (deleted)   │
  │ tuple (xmin=1005, xmax=0,    data='new')      ← live             │
  └───────────────────────────────────────────────────────────────────┘
After VACUUM:
  ┌───────────────────────────────────────────────────────────────────┐
  │ tuple (xmin=1000, xmax=0,    data='active')   ← live             │
  │ [free space]                                  ← reclaimed        │
  │ [free space]                                  ← reclaimed        │
  │ tuple (xmin=1005, xmax=0,    data='new')      ← live             │
  └───────────────────────────────────────────────────────────────────┘
```

VACUUM reclaims dead tuple space and makes it available for future inserts. It also updates the **free space map (FSM)** — a compact data structure Postgres consults to find pages with room for new rows without extending the file.

VACUUM does **not** compact pages or return space to the OS (that is `VACUUM FULL`, which holds an `AccessExclusiveLock` and rebuilds the table — almost never appropriate in production). Regular VACUUM is non-blocking: it acquires only a `ShareUpdateExclusiveLock`, which allows concurrent reads and writes.

### What VACUUM actually does — the checklist

1. **Scans heap pages** for dead tuples (those whose `xmax` is older than the oldest active transaction).
2. **Marks dead index entries** as recyclable in each index on the table (an index vacuum pass before the heap pass).
3. **Reclaims free space** on heap pages and updates the FSM.
4. **Updates the visibility map** — sets the bit for any page where every tuple is now visible to all transactions. This is what enables Index-Only Scans (Module 05) and speeds future VACUUM runs (VM bit set → can skip that page).
5. **Advances `relfrozenxid`** — the freeze marker, critical for wraparound prevention (explained below).

### Transaction ID wraparound — the most dangerous PostgreSQL failure mode

PostgreSQL uses 32-bit transaction IDs (XIDs). There are ~2.1 billion possible XIDs. The MVCC visibility logic uses a "modular arithmetic" comparison: a transaction with XID N can see tuples committed before XID N. After 2^31 transactions (~2.1 billion), the counter wraps around and suddenly *old* rows look *newer* than *new* transactions — MVCC breaks completely.

Postgres prevents this by **freezing** old tuples: replacing their `xmin` with a special sentinel value (`FrozenTransactionId = 2`) that is considered older than every real XID. Once frozen, a tuple is forever visible to all transactions, and the original XID can be reused.

```
The danger zone:
  XID counter: 0 ─────────────────────────────────────────► 2,147,483,647
                                                              │
  If relfrozenxid of a table is more than 2B XIDs behind,   │
  Postgres REFUSES CONNECTIONS with:                         │
  "database is not accepting commands to avoid wraparound"   ▼
```

The `relfrozenxid` per table (in `pg_class`) and `datfrozenxid` per database tell you how old the oldest unfrozen XID is. Autovacuum runs an aggressive freeze pass when a table's XID age approaches `autovacuum_freeze_max_age` (default 200M transactions).

```sql
-- Monitor all tables for XID age — sort by most dangerous first:
SELECT
    schemaname,
    relname,
    age(relfrozenxid) AS xid_age,
    pg_size_pretty(pg_total_relation_size(oid)) AS total_size
FROM pg_class
WHERE relkind = 'r'
ORDER BY age(relfrozenxid) DESC
LIMIT 20;

-- Database-level freeze boundary (if this is close to 2B, act now):
SELECT datname, age(datfrozenxid) AS freeze_age
FROM   pg_database
ORDER  BY freeze_age DESC;

-- Manually force a freeze pass on a table near the limit:
VACUUM FREEZE ANALYZE orders;
```

> **War story pattern.** The canonical "wraparound incident" happens to systems that ran fine for years: a low-traffic analytics database that barely VACUUMs, or a table that autovacuum skipped because it was locked during every scheduled pass. The database issues a WARNING at age 1.6B, an ERROR at 1.8B, and shuts down connections at ~2B. The recovery is `VACUUM FREEZE` in single-user mode — a painful hours-long operation. Monitoring `age(relfrozenxid)` and alerting at 500M is non-negotiable.

### Autovacuum — the background maintenance worker

Autovacuum is a set of background workers (count controlled by `autovacuum_max_workers`, default 3) that run VACUUM and ANALYZE automatically. The trigger thresholds are:

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `autovacuum_vacuum_threshold` | 50 | Min dead tuples before triggering |
| `autovacuum_vacuum_scale_factor` | 0.2 | Fraction of table size added to threshold |
| `autovacuum_analyze_threshold` | 50 | Min row changes before ANALYZE |
| `autovacuum_analyze_scale_factor` | 0.1 | Fraction of table size added to ANALYZE threshold |
| `autovacuum_vacuum_cost_delay` | 2ms | Pause between I/O bursts (throttles autovacuum) |
| `autovacuum_vacuum_cost_limit` | 200 | I/O "tokens" consumed per burst |

The default 20 % scale factor means autovacuum triggers only after 20 % of a table's rows have been changed. For a 100 M row table, that's 20 M dead rows before autovacuum fires — a lot of dead weight accumulating. Large, busy tables need per-table overrides:

```sql
-- Tune autovacuum aggressively for a high-write table:
ALTER TABLE orders SET (
    autovacuum_vacuum_scale_factor = 0.01,    -- trigger at 1% change
    autovacuum_vacuum_threshold = 1000,       -- or 1000 dead tuples
    autovacuum_analyze_scale_factor = 0.005,
    autovacuum_vacuum_cost_delay = 0,         -- no throttle (careful: I/O impact)
    autovacuum_vacuum_cost_limit = 800
);
```

### Monitoring autovacuum

```sql
-- Currently running autovacuum workers:
SELECT pid, query, now() - xact_start AS duration, wait_event_type, wait_event
FROM   pg_stat_activity
WHERE  query ILIKE 'autovacuum%';

-- Per-table vacuum stats:
SELECT
    schemaname,
    relname,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    n_dead_tup,
    n_live_tup,
    round(n_dead_tup::numeric / nullif(n_live_tup + n_dead_tup, 0) * 100, 1) AS dead_pct
FROM   pg_stat_user_tables
ORDER  BY n_dead_tup DESC
LIMIT  20;
```

A `dead_pct` above 20–30 % on a table that has recent `last_autovacuum` suggests autovacuum is falling behind writes faster than it can clean. Fix: reduce `autovacuum_vacuum_scale_factor`, increase `autovacuum_max_workers`, or increase `autovacuum_vacuum_cost_limit`.

---

## Connection Pooling with PgBouncer

### Why you need a connection pooler

Each Postgres backend process consumes ~5–10 MB of RAM just for the process overhead, plus the memory for its per-process `work_mem` allocations. `max_connections = 200` means Postgres will consume 1–2 GB for idle connection overhead alone, before a single query runs.

More critically: Postgres's scheduler is not designed for thousands of concurrent backends. Each backend is a separate OS process. At 500+ active connections (not idle — *actively executing queries*), context-switching overhead becomes measurable and throughput degrades.

The solution is a connection pooler that sits between your application and Postgres:

```
┌──────────────────────────────────────────────────────────────────────┐
│  App servers (200 pods, 50 connections each = 10,000 app connections)│
└─────────────────────────────┬────────────────────────────────────────┘
                              │ 10,000 connections
                    ┌─────────▼─────────┐
                    │    PgBouncer      │
                    │  connection pool  │
                    │  (single process) │
                    └─────────┬─────────┘
                              │ 50–200 connections
                    ┌─────────▼─────────┐
                    │    PostgreSQL     │
                    │  max_connections  │
                    │      = 200        │
                    └───────────────────┘
```

### PgBouncer pooling modes

| Mode | How it works | When to use |
|------|-------------|-------------|
| **Session pooling** | One server connection per client connection; held for the client's lifetime | Safe with `SET`, prepared statements, `LISTEN/NOTIFY`, advisory locks |
| **Transaction pooling** | Server connection assigned per transaction; released after `COMMIT`/`ROLLBACK` | Most web apps; incompatible with session-level `SET`, named prepared statements |
| **Statement pooling** | Server connection released after each statement | Almost never: breaks multi-statement transactions |

Transaction pooling is the mode that actually solves the overload problem. At 10,000 app connections with average 50 ms transactions and 5 ms think time, only ~10,000 * (5/55) ≈ 900 connections are *active at any instant*. PgBouncer multiplexes those 900 active requests onto 100–200 Postgres backends.

```ini
; /etc/pgbouncer/pgbouncer.ini
[databases]
dojo = host=127.0.0.1 port=5432 dbname=dojo

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 10000
default_pool_size = 50          ; server connections per database-user pair
min_pool_size = 10
reserve_pool_size = 5
reserve_pool_timeout = 3
server_idle_timeout = 600
```

### Incompatibilities to watch for in transaction mode

- **Session-level `SET` commands** persist on the server connection, which is then handed to another client: use `SET LOCAL` or avoid session settings entirely.
- **Named prepared statements** (`PREPARE foo AS ...`) are tied to a server connection, which a different client will inherit. Use unnamed prepared statements (the default in most ORMs) or enable `server_reset_query = DEALLOCATE ALL` in PgBouncer.
- **`LISTEN/NOTIFY`** requires a persistent server connection — use session mode or a dedicated direct connection for `LISTEN`.
- **Advisory locks** (`pg_advisory_lock`) are session-scoped — same issue as `LISTEN`.

---

## Declarative partitioning

Partitioning divides a large table into physical sub-tables (partitions) while presenting a single logical interface to queries. Postgres has supported declarative partitioning since version 10.

### Why partition

- **Pruning:** the planner skips partitions whose bounds cannot contain matching rows — a `WHERE event_date = '2024-06-15'` on a monthly-partitioned table reads only the June 2024 partition.
- **Maintenance:** `VACUUM` and `REINDEX` on a single partition are faster than on the full table. Dropping an old partition (`DROP TABLE events_2022`) is O(1) vs. a `DELETE WHERE` which requires VACUUM.
- **Parallelism:** Postgres can scan partitions in parallel using parallel workers.

### Range partitioning example — time-series events

```sql
CREATE TABLE events (
    id          bigserial,
    user_id     bigint        NOT NULL,
    event_type  text          NOT NULL,
    occurred_at timestamptz   NOT NULL,
    payload     jsonb
) PARTITION BY RANGE (occurred_at);

-- Create monthly partitions:
CREATE TABLE events_2024_01 PARTITION OF events
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

CREATE TABLE events_2024_02 PARTITION OF events
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');

-- Default partition catches rows that don't match any range (optional but useful):
CREATE TABLE events_default PARTITION OF events DEFAULT;

-- Indexes are created per partition; or use CREATE INDEX ON events (which cascades):
CREATE INDEX ON events (user_id, occurred_at);
-- This creates the index on every existing partition and automatically on new ones.
```

### Partition pruning in action

```sql
-- Planner should scan only the January partition:
EXPLAIN SELECT count(*) FROM events WHERE occurred_at >= '2024-01-01' AND occurred_at < '2024-02-01';
-- Look for: "Partitions selected: 1 of N"

-- If pruning is NOT happening, check that the column type matches exactly:
-- occurred_at::date won't prune a timestamptz partition correctly.
-- Use >= and < with explicit timestamptz literals.

-- Dynamic pruning (planner cannot see the value at plan time, but executor can prune at runtime):
PREPARE q(timestamptz, timestamptz) AS
    SELECT count(*) FROM events WHERE occurred_at >= $1 AND occurred_at < $2;
EXPLAIN (ANALYZE) EXECUTE q('2024-01-01', '2024-02-01');
-- Look for: "Subplans Removed: N" (runtime pruning)
```

### List and hash partitioning

```sql
-- List partitioning (region-based sharding):
CREATE TABLE orders (
    id       bigserial,
    region   text NOT NULL,
    amount   numeric,
    ...
) PARTITION BY LIST (region);

CREATE TABLE orders_us  PARTITION OF orders FOR VALUES IN ('US');
CREATE TABLE orders_eu  PARTITION OF orders FOR VALUES IN ('DE', 'FR', 'NL', 'UK');
CREATE TABLE orders_apac PARTITION OF orders FOR VALUES IN ('IN', 'JP', 'SG');

-- Hash partitioning (uniform distribution, no business meaning needed):
CREATE TABLE sessions (
    id       uuid DEFAULT gen_random_uuid(),
    user_id  bigint,
    ...
) PARTITION BY HASH (user_id);

CREATE TABLE sessions_p0 PARTITION OF sessions FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE sessions_p1 PARTITION OF sessions FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE sessions_p2 PARTITION OF sessions FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE sessions_p3 PARTITION OF sessions FOR VALUES WITH (MODULUS 4, REMAINDER 3);
```

### Partition maintenance

```sql
-- Attach an existing table as a new partition (zero-downtime migration):
CREATE TABLE events_2024_06 (LIKE events INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
-- Load data into events_2024_06 independently, then attach:
ALTER TABLE events ATTACH PARTITION events_2024_06
    FOR VALUES FROM ('2024-06-01') TO ('2024-07-01');

-- Detach and drop an old partition (instant — no DELETE + VACUUM needed):
ALTER TABLE events DETACH PARTITION events_2022_01 CONCURRENTLY;
DROP TABLE events_2022_01;

-- Automate partition creation (use pg_cron or a scheduled job):
-- Create next month's partition on the 25th of each month.
```

---

## Key configuration parameters

These are the parameters that matter most for a production Postgres instance. Start here when tuning a new instance or diagnosing degraded performance.

### `shared_buffers` — the Postgres buffer pool

The amount of memory Postgres uses for caching data pages. Default is 128 MB (absurdly low). The standard recommendation is **25 % of total RAM**.

```
Total RAM: 16 GB
  shared_buffers = 4 GB       ← Postgres page cache
  OS page cache ≈ 8 GB        ← Linux caches Postgres files transparently
  work_mem, connections, etc. ← ~2 GB
  OS + other processes        ← 2 GB
```

Do not set `shared_buffers` above 40 % of RAM. Postgres relies heavily on the OS page cache for sequential reads; starving the OS cache degrades performance. The two caches work together.

```sql
ALTER SYSTEM SET shared_buffers = '4GB';
-- Requires restart (not just reload):
-- pg_ctl restart -D $PGDATA
```

### `work_mem` — per-sort/hash operation memory

Memory allocated per *sort operation* or *hash table* per *query*. Default is 4 MB. A query with 10 sort nodes can use up to `10 * work_mem` if all nodes run concurrently.

**Danger zone:** setting `work_mem = 256MB` globally on a system with `max_connections = 200` means Postgres *could* allocate `200 * 10 * 256MB = 512 GB` — far more than available RAM. In practice, not all connections run sorts simultaneously, but the risk is real.

**Safe approach:** keep the global default low (16–64 MB) and set it per-session for known heavy analytical queries:

```sql
-- Global: conservative default
ALTER SYSTEM SET work_mem = '32MB';
SELECT pg_reload_conf();

-- Per-session for a reporting query:
SET work_mem = '512MB';
SELECT ... ORDER BY ... LIMIT 1000;
RESET work_mem;

-- Detect spills in pg_stat_statements (Postgres 16+):
SELECT query, temp_blks_written
FROM   pg_stat_statements
ORDER  BY temp_blks_written DESC
LIMIT  10;
-- temp_blks_written > 0 indicates a sort/hash that spilled to disk.
-- Those queries benefit from a higher work_mem set per-session.
```

### `effective_cache_size` — the planner hint

This does **not** allocate memory — it is purely a hint to the planner about how much of the OS page cache is available for caching Postgres data files. The planner uses this to adjust the cost of index scans (more cache → lower random I/O cost → indexes more attractive).

```sql
-- Set to 75% of total RAM (the OS can cache Postgres files from this budget):
ALTER SYSTEM SET effective_cache_size = '12GB';  -- on a 16 GB server
SELECT pg_reload_conf();
```

Leaving this at the default (4 GB) on a 32 GB server causes the planner to underestimate how much data is in cache and produce overly conservative plans (more seq scans, fewer index scans).

### `max_connections` — keep it low

Each Postgres backend is an OS process. At 1000 connections, process scheduling overhead alone consumes CPU. The correct value is usually much lower than developers expect:

```
Rule of thumb for transaction-pooled workloads:
  max_connections = 4 * cpu_cores + 10

For a 16-core server: max_connections = 74
Use PgBouncer to multiplex application connections onto this pool.
```

Set `max_connections` conservatively, deploy PgBouncer, and set `PgBouncer.default_pool_size` to your computed `max_connections` minus a few for admin connections.

```sql
-- Reserve connections for superuser maintenance (prevent lockout under load):
ALTER SYSTEM SET superuser_reserved_connections = 3;
-- With max_connections=74, regular users can use 71; superusers can always connect.
```

### `wal_buffers` and checkpoint parameters

```sql
-- WAL buffers: default is 1/32 of shared_buffers but auto (min 64kB, max 16MB)
-- Usually leave at -1 (auto). Only raise if pg_stat_bgwriter shows many wal_writes.

-- Checkpoint spacing: increase to reduce I/O spikes from frequent checkpoints:
ALTER SYSTEM SET checkpoint_completion_target = 0.9;  -- spread I/O over 90% of interval
ALTER SYSTEM SET checkpoint_timeout = '15min';        -- default 5min; increase for write-heavy
ALTER SYSTEM SET max_wal_size = '4GB';                -- allow WAL to grow before forced checkpoint
```

---

## `pg_stat_statements` — the production monitoring baseline

`pg_stat_statements` is the most important Postgres extension for production monitoring. It tracks cumulative statistics for every distinct query string executed — calls, total time, mean time, rows, shared buffer hits and reads, temp blocks written.

```sql
-- Enable it (requires restart if not in shared_preload_libraries):
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';
-- Restart Postgres, then:
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Top 10 slowest queries by mean execution time:
SELECT
    left(query, 80) AS query,
    calls,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    round(total_exec_time::numeric / 1000, 2) AS total_sec,
    round(stddev_exec_time::numeric, 2) AS stddev_ms,
    rows
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;

-- Top 10 by total time (the biggest time sinks even if individually fast):
SELECT
    left(query, 80) AS query,
    calls,
    round(total_exec_time::numeric / 1000, 2) AS total_sec,
    round(mean_exec_time::numeric, 2) AS mean_ms
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;

-- Queries with highest disk spill (work_mem candidates):
SELECT
    left(query, 80) AS query,
    calls,
    temp_blks_written,
    round(mean_exec_time::numeric, 2) AS mean_ms
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 10;

-- Reset stats (do this after a tuning change to get clean baselines):
SELECT pg_stat_statements_reset();
```

---

## Extensions worth knowing

### `pgvector` — vector similarity search

pgvector adds a `vector` column type and index types for approximate nearest-neighbour search — essential for semantic search, RAG pipelines, and recommendation systems.

```sql
CREATE EXTENSION IF NOT EXISTS vector;

-- Store embeddings alongside structured data:
CREATE TABLE documents (
    id          bigserial PRIMARY KEY,
    title       text,
    embedding   vector(1536)   -- OpenAI text-embedding-3-small dimension
);

-- IVFFlat index: clusters vectors into `lists` buckets; faster but approximate.
-- Build AFTER data is loaded (accuracy depends on representative data):
CREATE INDEX idx_docs_embedding_ivfflat
    ON documents USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);

-- HNSW index (Postgres 0.5.0+): better recall, more memory, slower build:
CREATE INDEX idx_docs_embedding_hnsw
    ON documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- Cosine similarity search (top 5 nearest neighbours):
SELECT title, 1 - (embedding <=> '[0.1, 0.2, ...]'::vector) AS similarity
FROM   documents
ORDER  BY embedding <=> '[0.1, 0.2, ...]'::vector
LIMIT  5;

-- Set probes at query time to trade recall for speed:
SET ivfflat.probes = 10;   -- check 10 of the 100 clusters (default 1)
```

**Tuning tips:**
- `lists` ≈ `sqrt(row_count)` for typical use. For 1M rows, `lists = 1000`.
- For HNSW, `m = 16` is a good default; increase for higher recall at higher memory cost.
- Run `VACUUM ANALYZE` after bulk loading before building the index.

### Other notable extensions

```sql
-- pg_trgm: trigram similarity for fuzzy text search and ILIKE acceleration
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_products_name_trgm ON products USING GIN (name gin_trgm_ops);
SELECT * FROM products WHERE name % 'postresql';   -- fuzzy match (typos)
SELECT * FROM products WHERE name ILIKE '%ostgres%';  -- now uses the GIN index

-- pgcrypto: encryption functions
CREATE EXTENSION IF NOT EXISTS pgcrypto;
SELECT crypt('my_password', gen_salt('bf', 10));   -- bcrypt

-- pg_partman: automated partition management (create, retain, drop)
-- Manages monthly/weekly/daily partition sets without manual DDL.

-- timescaledb: time-series extension built on Postgres (compression, continuous aggregates)
-- PostGIS: full spatial database (geometry types, R-tree GiST, spatial functions)
```

---

## Debugging: autovacuum falling behind

**Symptom:** table's `n_dead_tup` keeps growing despite autovacuum running; query performance degrades; table bloat increases.

```sql
-- 1. Check if autovacuum is actually running on the table:
SELECT relname, last_autovacuum, last_autoanalyze, n_dead_tup, n_live_tup
FROM   pg_stat_user_tables
WHERE  relname = 'orders';

-- 2. Check for long-running transactions blocking VACUUM
-- (VACUUM cannot remove tuples newer than the oldest active transaction's xmin):
SELECT pid, xact_start, state, wait_event, left(query, 60) AS query
FROM   pg_stat_activity
WHERE  state != 'idle'
ORDER  BY xact_start ASC
LIMIT  5;
-- A transaction open for hours prevents VACUUM from reclaiming any dead tuples
-- created after it started. Kill the offending backend if safe:
-- SELECT pg_terminate_backend(pid);

-- 3. Check autovacuum cost throttle — is it sleeping too much?
SHOW autovacuum_vacuum_cost_delay;  -- default 2ms: sleeps 2ms per cost unit
SHOW autovacuum_vacuum_cost_limit;  -- default 200: triggers sleep every 200 cost units
-- On SSDs, set cost_delay=0 and cost_limit=800 for much faster autovacuum:
ALTER TABLE orders SET (
    autovacuum_vacuum_cost_delay = 0,
    autovacuum_vacuum_cost_limit = 800
);

-- 4. Increase autovacuum workers if multiple busy tables are competing:
ALTER SYSTEM SET autovacuum_max_workers = 6;
SELECT pg_reload_conf();

-- 5. Manual vacuum if you need immediate relief:
VACUUM (VERBOSE, ANALYZE) orders;
-- Watch the output: it tells you which index pages were cleaned, how many dead
-- tuples were reclaimed, and whether the visibility map was updated.
```

---

## Debugging: transaction ID wraparound

**Symptom:** `age(relfrozenxid)` approaching 1.5–2 billion; Postgres logs warnings; in extreme cases, the database refuses connections.

```sql
-- 1. Find the highest XID age across all tables:
SELECT
    schemaname || '.' || relname AS table_name,
    age(relfrozenxid) AS xid_age,
    pg_size_pretty(pg_total_relation_size(oid)) AS table_size
FROM pg_class
WHERE relkind IN ('r', 't')   -- regular tables and TOAST tables
ORDER BY age(relfrozenxid) DESC
LIMIT 20;

-- 2. If age > 150 million, run VACUUM FREEZE immediately:
VACUUM FREEZE VERBOSE orders;

-- 3. If age > 1.8 billion (emergency):
-- Postgres may refuse non-superuser connections. Connect as superuser and:
VACUUM FREEZE;   -- vacuums the entire database

-- 4. Prevent recurrence — tune aggressive freeze:
ALTER SYSTEM SET autovacuum_freeze_max_age = 150000000;  -- trigger freeze at 150M (vs 200M default)
ALTER SYSTEM SET vacuum_freeze_min_age = 1000000;        -- freeze tuples older than 1M txns
SELECT pg_reload_conf();
```

---

## Debugging: work_mem spills to disk

**Symptom:** sort-heavy queries are slow; `EXPLAIN ANALYZE` shows `Sort Method: external merge Disk: NMB`; `pg_stat_statements.temp_blks_written` is nonzero.

```sql
-- 1. Find queries that spill to disk:
SELECT
    left(query, 100) AS query,
    calls,
    temp_blks_written,
    round(mean_exec_time::numeric, 2) AS mean_ms
FROM   pg_stat_statements
WHERE  temp_blks_written > 0
ORDER  BY temp_blks_written DESC
LIMIT  10;

-- 2. Reproduce and confirm with EXPLAIN ANALYZE:
SET work_mem = '4MB';   -- force small work_mem to confirm the spill
EXPLAIN (ANALYZE, BUFFERS)
SELECT user_id, count(*), sum(amount)
FROM   orders
GROUP  BY user_id
ORDER  BY sum(amount) DESC;
-- Sort Method: external merge  Disk: 28000kB   ← spilling

-- 3. Fix for the specific query:
SET work_mem = '256MB';
EXPLAIN (ANALYZE, BUFFERS) <same query>;
-- Sort Method: quicksort  Memory: 48kB   ← fits in memory now

-- 4. Permanent fix — identify which queries need more work_mem and
-- set it at the role level for reporting users only:
ALTER ROLE reporting_user SET work_mem = '256MB';
-- This avoids the global memory multiplication risk while fixing the
-- real pain points.

-- 5. On Postgres 16+: check for hash batch spills too:
SELECT query, local_blks_written FROM pg_stat_statements
ORDER BY local_blks_written DESC LIMIT 5;
```

---

## Checkpoint

You are ready for the operations challenges when you can, without looking anything up:

1. Explain in one paragraph why VACUUM cannot simply delete dead tuples immediately on UPDATE, and what data structure it updates to enable Index-Only Scans.
2. Describe the transaction ID wraparound failure mode: what is the maximum XID value, what happens when it is reached, what Postgres does at 200M and 1.8B transactions, and how you monitor proximity to the limit.
3. State the difference between `VACUUM` and `VACUUM FULL`, including the lock each holds, and when you would ever run `VACUUM FULL` in production.
4. Explain PgBouncer transaction pooling: why it allows 10,000 app connections with only 100 Postgres backends, and name two features that are incompatible with transaction mode and why.
5. Given `shared_buffers = 128MB` on a 32 GB server, state whether this is correct, what value you would set, and whether a restart is required to apply it.
6. A nightly reporting job that runs `ORDER BY` on 50 M rows shows `Sort Method: external merge Disk: 1200 MB`. What causes this, and what is the safest way to fix it without changing the global `work_mem`?
7. You see `age(relfrozenxid) = 1,750,000,000` for the `events` table. What is the immediate risk, what command do you run right now, and what configuration change prevents recurrence?
8. Name the two `pg_stat_statements` columns you would check to find (a) the single slowest query by mean latency, and (b) the query that spills most to disk.
9. Describe IVFFlat vs HNSW index types for pgvector: the trade-off each makes between build time, memory, and recall; and the parameter you tune at query time for IVFFlat.

➡ Next up: **Module 08 — Replication & High Availability** — streaming replication, logical decoding, read replicas, and failover with Patroni.
