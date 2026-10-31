# PostgreSQL Architecture & Processes

> **Module 01 · Course 18** — Most engineers treat Postgres as a black box: send SQL, receive rows. That model breaks the first time you hit "too many connections", see a checkpoint I/O spike flatten your application, or can't explain why `pg_cancel_backend` does nothing. This module opens the box and walks through every moving part.

PostgreSQL uses a **process-per-connection model**: every client connection is a separate OS process. This single architectural fact explains every behaviour you'll encounter at scale — connection overhead, shared memory layout, how crash recovery works, and why VACUUM has to be its own background daemon. Understand the process model and most of the advanced behaviour follows from it.

---

## The Process Model

When you start a PostgreSQL server, one process appears: the **postmaster**. It owns the shared memory segment, listens on the socket (port 5432 by default), and forks a dedicated **backend** process for every incoming connection. It also manages a set of background worker processes and restarts them if they crash.

```
  ┌──────────────────────────── OS ─────────────────────────────────┐
  │                                                                  │
  │  postmaster (pid 1234)                                           │
  │  ├── shared memory  ← allocated at startup, mapped by all procs  │
  │  │                                                               │
  │  ├── backend (pid 1300) ── psql session, alice@mydb              │
  │  ├── backend (pid 1301) ── JDBC pool connection #1               │
  │  ├── backend (pid 1302) ── JDBC pool connection #2               │
  │  │          …                                                    │
  │  │                                                               │
  │  ├── bgwriter          (pid 1250)                                │
  │  ├── checkpointer      (pid 1251)                                │
  │  ├── walwriter         (pid 1252)                                │
  │  ├── autovacuum launcher (pid 1253)                              │
  │  │   ├── autovacuum worker (pid 1400) — vacuuming orders         │
  │  │   └── autovacuum worker (pid 1401) — analyzing customers      │
  │  ├── logical replication launcher (pid 1254)                     │
  │  └── stats collector  (pid 1255) [PG ≤ 14; shared mem in PG 15+] │
  └──────────────────────────────────────────────────────────────────┘
```

### Why processes, not threads?

Postgres predates the era when POSIX threading was reliable and portable. A process-per-connection model was chosen for isolation: a buggy backend that corrupts its own heap, dereferences a null pointer, or takes an unhandled signal crashes that one process and is restarted by the postmaster — all other connections survive. A threading model would share a single heap; one bad memory write could corrupt the query results of an unrelated client.

Consequences worth internalizing:

- **A crashing backend does not bring down the cluster.** The postmaster detects the child's death via `SIGCHLD`, marks the process dead, and for shared state corruptions initiates a fast restart (all backends are terminated, shared memory is re-initialized). For normal crashes only the client connection dies.
- **Spawning a backend is a real `fork()`.** On Linux, `fork` is cheap because of copy-on-write page tables, but at 1000 connections/second the bookkeeping is measurable. Every backend starts with a copy of the postmaster's virtual address space mapping; shared memory is mapped read-write by all.
- **Context switch cost grows with connection count.** At 200 backends all trying to access shared_buffers, the kernel scheduler overhead is non-trivial. This is why **PgBouncer** (or similar connection pooler) is not optional at any serious production scale.

---

## Shared Memory Layout

At startup the postmaster calls `shmget()` (or `mmap` with `MAP_SHARED` on newer kernels) to allocate one large shared memory segment. Every backend, checkpointer, bgwriter, and walwriter maps this same physical memory — writes by one are immediately visible to all others.

```
  shared memory segment
  ┌────────────────────────────────────────────────────────────────┐
  │  shared_buffers  (default 128 MB; tune to ~25% of total RAM)   │
  │  8192-byte page frames that cache heap and index pages         │
  │  each frame tagged with (relfilenode, fork, block_number)      │
  ├────────────────────────────────────────────────────────────────│
  │  WAL buffers  (wal_buffers, default ~4 MB)                     │
  │  in-flight WAL records before the walwriter flushes them       │
  ├────────────────────────────────────────────────────────────────│
  │  lock table  (max_locks_per_transaction × max_connections)     │
  │  every row lock, relation lock, and advisory lock in flight    │
  ├────────────────────────────────────────────────────────────────│
  │  procarray  (one entry per max_connections + autovacuums)      │
  │  per-backend: pid, current XID, snapshot info, cancel token    │
  ├────────────────────────────────────────────────────────────────│
  │  CLOG buffers  (pg_xact slabs)                                 │
  │  in-memory cache of commit-status bits (2 bits per XID)        │
  ├────────────────────────────────────────────────────────────────│
  │  SLRU caches: multixact, subtrans, async, serial               │
  ├────────────────────────────────────────────────────────────────│
  │  background worker slots (max_worker_processes entries)        │
  └────────────────────────────────────────────────────────────────┘
```

### How a backend reads a tuple (the buffer path)

1. Compute the page address: relation file path + (block_number × 8192).
2. Acquire the buffer pool lock and search the hash table keyed on (relfilenode, fork, blkno).
3. **Cache hit** → pin the buffer frame, acquire a lightweight lock on the page, read the tuple, release and unpin.
4. **Cache miss** → find a victim frame using the **clock-sweep** eviction policy, write it back if dirty (via bgwriter or inline), read the 8 KB page from disk/OS cache into the frame, then proceed as a hit.

The OS has its own page cache below Postgres. A "cache miss" in shared_buffers may still be served from the OS cache without a physical disk read — this is why `effective_cache_size` (which you set to what you *think* the OS cache is) matters to the query planner even though Postgres doesn't control it.

### Buffer pinning and eviction pressure

A backend holds a **pin** on a buffer frame while it's actively reading or writing that page. Pinned frames are ineligible for eviction. A query that scans a large table — say, a 10 GB sequential scan — pins and unpins pages rapidly; after a configurable threshold, Postgres bypasses shared_buffers entirely for sequential scans (`enable_seqscan` doesn't control this; it's the ring buffer for bulk reads). This prevents large sequential scans from thrashing the buffer pool and evicting hot OLTP pages.

Use `pg_buffercache` to inspect what's actually in the pool:

```sql
CREATE EXTENSION IF NOT EXISTS pg_buffercache;

-- top 20 tables by cached pages
SELECT c.relname,
       count(*)                               AS buffers,
       round(count(*) * 8192 / 1048576.0, 1) AS mb,
       round(count(*) * 100.0 / (SELECT count(*) FROM pg_buffercache), 2) AS pct
FROM pg_buffercache b
JOIN pg_class c ON c.relfilenode = b.relfilenode
WHERE b.reldatabase IN (0, (SELECT oid FROM pg_database WHERE datname = current_database()))
GROUP BY c.relname
ORDER BY buffers DESC
LIMIT 20;
```

---

## The Data Directory

`$PGDATA` is the root of everything Postgres owns on disk. Understanding its layout is essential when you're diagnosing disk pressure, inspecting a stopped cluster, or recovering from a crash.

```
$PGDATA/
├── PG_VERSION                   # single line: major version, e.g. "16"
├── postgresql.conf              # main configuration file
├── postgresql.auto.conf         # overrides set via ALTER SYSTEM (don't edit by hand)
├── pg_hba.conf                  # host-based auth rules
├── pg_ident.conf                # ident username mapping
│
├── global/
│   ├── pg_control               # CRITICAL: checkpoint LSN, timeline ID, DB state
│   └── pg_filenode.map          # OID→relfilenode for shared catalog tables
│
├── base/
│   ├── 1/                       # template1 database files
│   ├── 16384/                   # your database (OID from pg_database.oid)
│   │   ├── 12345                # heap file for a table (relation OID or relfilenode)
│   │   ├── 12345.1              # second 1-GB segment of same heap
│   │   ├── 12345_fsm            # free space map (which blocks have free space)
│   │   ├── 12345_vm             # visibility map (which blocks are all-visible)
│   │   ├── 16789                # index file
│   │   └── …
│
├── pg_wal/
│   ├── 000000010000000000000001  # WAL segment, 16 MB by default
│   ├── 000000010000000000000002
│   └── …
│
├── pg_xact/
│   └── 0000                     # CLOG: 2 bits per XID (committed/aborted/in-progress)
│
├── pg_subtrans/                 # sub-transaction status
├── pg_multixact/                # multi-transaction IDs (shared row locks)
├── pg_replslot/                 # replication slot state (can grow unbounded — watch it)
├── pg_tblspc/                   # symlinks to tablespace directories
├── pg_logical/                  # logical decoding state
└── postmaster.pid               # PID + port + start time (lock file)
```

### Files you must know cold

**`$PGDATA/global/pg_control`** — the most important file in the cluster. It records:
- The last completed checkpoint's LSN and time
- The cluster state: `in production`, `in crash recovery`, `shut down`
- The timeline ID (increments on every failover)
- The compile-time block size (BLCKSZ = 8192 by default)

Read it without starting the server:
```bash
pg_controldata $PGDATA
# or, inside a Docker container:
docker exec dojo-pg pg_controldata /var/lib/postgresql/data
```

If `pg_control` is missing or corrupt, Postgres refuses to start and you're into manual recovery territory.

**`$PGDATA/postmaster.pid`** — a stale lock file from a dirty shutdown blocks a new start with `FATAL: lock file "postmaster.pid" already exists`. Only delete it if you are absolutely certain no Postgres process is running (check with `ps aux | grep postgres`).

**`$PGDATA/pg_wal/`** — WAL segments accumulate when archiving is enabled (`archive_command`) or when a replication slot holds them back. An unbounded `pg_wal/` directory fills the disk and kills the cluster. More on this in Module 04.

**Relation files under `base/`** — each table and index is a file (or a set of 1 GB segment files). The filename is the `relfilenode` from `pg_class.relfilenode`, not the OID you see in user-visible queries. After a `VACUUM FULL` or `CLUSTER`, the relfilenode changes.

```sql
-- find the filename for a table
SELECT pg_relation_filepath('orders');
-- e.g. base/16384/12345

-- file size of a relation
SELECT pg_size_pretty(pg_relation_size('orders'));
SELECT pg_size_pretty(pg_total_relation_size('orders'));  -- includes indexes and TOAST
```

---

## Background Processes in Detail

### bgwriter (background writer)

The bgwriter's only job is to reduce **backend-induced I/O** by proactively writing dirty shared_buffers pages to the OS page cache — not to disk (it does not call `fsync`). Without it, the first backend that needs a clean buffer frame to load a new page would have to evict and write back a dirty frame inline, causing unpredictable latency spikes in query execution.

Key parameters:
```sql
SHOW bgwriter_delay;          -- default 200ms (wakeup interval)
SHOW bgwriter_lru_maxpages;   -- default 100 pages per round
SHOW bgwriter_lru_multiplier; -- default 2.0 (demand multiplier for look-ahead)
```

Monitor its effectiveness:
```sql
SELECT buffers_clean, buffers_backend, buffers_alloc,
       buffers_backend::float / nullif(buffers_alloc, 0) AS backend_write_ratio
FROM pg_stat_bgwriter;
```

`buffers_backend_fsync` > 0 indicates backends are calling `fsync` themselves — this means the checkpointer is lagging and is a sign of I/O saturation.

### checkpointer

The checkpointer is the process responsible for durability: it is the one that calls `fsync`. It runs on two triggers:

1. **Time-based**: every `checkpoint_timeout` (default 5 minutes)
2. **Size-based**: when `pg_wal/` has grown by `max_wal_size` (default 1 GB) since the last checkpoint

A checkpoint proceeds in phases:
1. Write a checkpoint WAL record marking the start LSN
2. Identify all dirty pages in shared_buffers that need to be written
3. Spread the writes over `checkpoint_completion_target × checkpoint_timeout` (default 0.9 × 5min = 4.5 minutes) — this smoothing prevents the "checkpoint spike" that would otherwise jam all I/O into a short window
4. Call `fsync` on every data file that received new writes
5. Update `pg_control` with the checkpoint LSN and time

```
timeline:  |──────────────────── 5 min ────────────────────|
                 checkpoint_completion_target = 0.9
           |──────── 4.5 min: spread-out page writes ───────|►fsync+pg_control
```

**What goes wrong:** If dirty pages accumulate faster than the checkpointer can drain them (heavy write workload), the size-based trigger fires before the time-based one, causing more frequent checkpoints. Each checkpoint writes all dirty pages since the last one — if the workload is write-heavy, this becomes a feedback loop. The fix is either faster storage, a larger `shared_buffers` (so the working set fits in memory), or a smaller write rate.

Monitor checkpoints:
```sql
SELECT checkpoints_timed, checkpoints_req,
       checkpoint_write_time, checkpoint_sync_time,
       buffers_checkpoint
FROM pg_stat_bgwriter;
```

`checkpoints_req` (size-based triggers) growing faster than `checkpoints_timed` (time-based) is the alert signal.

### walwriter

The walwriter flushes the in-memory WAL buffer to WAL segment files on disk. It wakes up every `wal_writer_delay` (default 200ms) or when the WAL buffer fills.

When a backend commits (`COMMIT`), it doesn't wait for the walwriter's next cycle — it triggers a synchronous WAL flush inline (unless `synchronous_commit = off`, which is a durability tradeoff you consciously take). The walwriter handles the asynchronous background flush for all other WAL records produced between commits.

```
backend A → generates WAL records → WAL buffer (shared memory)
backend B → generates WAL records → WAL buffer
                                         │
                                         ▼ walwriter wakes every 200ms
                                         ▼ or backend calls XLogFlush on commit
                                    pg_wal/00000001000000000000000N  (disk)
```

### autovacuum launcher and workers

The launcher wakes every `autovacuum_naptime` (default 1 minute), checks `pg_stat_user_tables` for tables that exceed the dead-tuple or analyze threshold, and spawns a worker for each qualifying table (up to `autovacuum_max_workers`, default 3).

Autovacuum workers are regular backends that connect to the database and run `VACUUM` and/or `ANALYZE`. They're throttled deliberately: `autovacuum_vacuum_cost_delay` (default 2ms per cost-limit hit) prevents autovacuum from saturating I/O. This throttling is appropriate on shared servers but can be tuned per-table for tables with high write rates.

Autovacuum is critical for three reasons:
1. **Dead tuple reclaim**: MVCC leaves dead tuple versions in heap pages. VACUUM marks them reusable. Without this, tables grow without bound.
2. **Hint bit setting and visibility map maintenance**: enables Index-Only Scans (Module 03) and skips full-page scans in future VACUUMs.
3. **Transaction ID wraparound prevention**: Postgres XIDs are 32-bit integers. At ~4 billion transactions the XID counter wraps. VACUUM advances `relfrozenxid` (the frozen-XID horizon) to prevent this. A table that goes too long without freezing triggers an emergency autovacuum that ignores all throttling and cost limits — you do not want to discover wraparound from a 2am alert.

```sql
-- tables approaching wraparound (age > 1.5 billion is alarming)
SELECT relname,
       age(relfrozenxid) AS xid_age,
       pg_size_pretty(pg_total_relation_size(oid)) AS size
FROM pg_class
WHERE relkind = 'r'
ORDER BY xid_age DESC
LIMIT 20;

-- system-wide oldest XID
SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY age DESC;
```

### stats collector (PG ≤ 14) / shared-memory stats (PG 15+)

In PG ≤ 14 a separate `stats collector` process received UDP messages from backends and maintained `pg_stat_user_tables`, `pg_stat_user_indexes`, and friends. In PG 15+ the stats subsystem was rewritten to use shared memory directly — the separate process is gone and stats are now immediately consistent (no more stale counters after a crash).

The practical impact: `pg_stat_user_tables.n_live_tup`, `n_dead_tup`, `last_autovacuum`, and the seq/index scan counters are the data autovacuum, EXPLAIN ANALYZE estimates, and your performance dashboards all rely on.

---

## The Client/Server Protocol (Version 3)

Postgres uses a custom binary protocol over TCP or a Unix socket. Version 3 (introduced in PG 7.4, still current) defines distinct message types for startup, authentication, query, and results. Understanding it matters when you're debugging connection timeouts, implementing a driver, or reading `pg_stat_activity.wait_event`.

### Startup and authentication

```
  client                                        server
    │                                               │
    │──── StartupMessage ────────────────────────►  │
    │     (protocol=3.0, user="app", database="mydb")│
    │                                               │
    │◄─── AuthenticationMD5Password / SCRAM ──────  │
    │──── PasswordMessage / SCRAM response ───────► │
    │◄─── AuthenticationOk ───────────────────────  │
    │                                               │
    │◄─── ParameterStatus (server_version, …) ────  │  repeated for each param
    │◄─── BackendKeyData (pid=1301, cancel_key=X) ─  │  ← save this
    │◄─── ReadyForQuery (status='I') ─────────────  │  'I'=idle, 'T'=in txn, 'E'=err
```

**BackendKeyData** is particularly important: it carries the backend PID and a random 32-bit cancel key. To interrupt a long-running query, the client driver opens a second TCP connection and sends a `CancelRequest` message with this PID+key. Postgres verifies the key and sends `SIGINT` to the matching backend. No authentication is required — the cancel key is the credential.

```bash
# From psql, you can see your own pid:
SELECT pg_backend_pid();

# Cancel it from another session (this is what Ctrl+C in psql does behind the scenes):
SELECT pg_cancel_backend(1301);
```

### Simple query protocol

Used by most clients for ad-hoc queries. One round trip per query.

```
  client                                        server
    │──── Query ("SELECT id, name FROM items") ──► │
    │◄─── RowDescription [(id: int4), (name: text)] │
    │◄─── DataRow [1, "Anvil"]                      │
    │◄─── DataRow [2, "Rope"]                       │
    │◄─── CommandComplete ("SELECT 2")              │
    │◄─── ReadyForQuery                             │
```

### Extended query protocol

Used by prepared statements and pipelining.

```
  client                                        server
    │──── Parse (name="s1", sql="SELECT … WHERE id=$1", paramTypes=[int4]) ──► │
    │──── Bind (portal="p1", statement="s1", params=[42]) ────────────────────► │
    │──── Describe (portal "p1") ─────────────────────────────────────────────► │
    │──── Execute (portal="p1", rowLimit=0) ──────────────────────────────────► │
    │──── Sync ────────────────────────────────────────────────────────────────► │
    │                                                                             │
    │◄─── ParseComplete ─────────────────────────────────────────────────────── │
    │◄─── BindComplete ──────────────────────────────────────────────────────── │
    │◄─── RowDescription ────────────────────────────────────────────────────── │
    │◄─── DataRow … DataRow ─────────────────────────────────────────────────── │
    │◄─── CommandComplete ───────────────────────────────────────────────────── │
    │◄─── ReadyForQuery ─────────────────────────────────────────────────────── │
```

Key benefits:
- **Parse once, bind+execute many times** — the parse/plan cost is paid only on the first call. Subsequent executes with different parameter values skip parsing and use the cached plan. JDBC's `PreparedStatement` and psycopg2's `cursor.execute(sql, params)` both use this path.
- **Type-safe parameter binding** — parameters are typed, not interpolated into the SQL string. This eliminates SQL injection at the protocol level.
- **Pipelining** (PG 16+) — send multiple Parse/Bind/Execute sequences without waiting for responses, reducing round-trip latency for multi-statement workloads.

### `wait_event` mapping to protocol state

When a backend is waiting, `pg_stat_activity.wait_event` tells you why:

```sql
SELECT pid, wait_event_type, wait_event, state, left(query, 60) AS query
FROM pg_stat_activity
WHERE wait_event IS NOT NULL;
```

Common events:
| `wait_event_type` | `wait_event`  | Meaning |
|-------------------|---------------|---------|
| `Client`          | `ClientRead`  | Backend sent all results; waiting for next query from client |
| `Lock`            | `relation`    | Waiting for a relation-level lock (DDL conflict, VACUUM FULL, etc.) |
| `Lock`            | `tuple`       | Waiting for a row-level lock (UPDATE/DELETE on a row held by another txn) |
| `Lock`            | `transactionid` | Waiting for another transaction to commit/abort |
| `IO`              | `DataFileRead` | Reading a page from disk (shared_buffers miss) |
| `IO`              | `WALWrite`    | Backend waiting for WAL flush to disk on commit |
| `IPC`             | `BgWorkerShutdown` | Waiting for a background worker to exit |

`Lock / transactionid` is what you see when one backend is blocked waiting for another to finish. `IO / DataFileRead` appearing frequently indicates a working set that doesn't fit in shared_buffers.

---

## Debugging: Architecture & Processes

### Too many connections

The single most common production Postgres incident. Symptom:

```
FATAL: remaining connection slots are reserved for non-replication superuser connections
FATAL: sorry, too many clients already
```

Diagnose the current state:

```sql
-- overall connection budget
SELECT current_setting('max_connections')::int         AS max,
       (SELECT count(*) FROM pg_stat_activity)         AS used,
       current_setting('max_connections')::int
         - (SELECT count(*) FROM pg_stat_activity)     AS free,
       current_setting('superuser_reserved_connections')::int AS reserved;

-- breakdown by state
SELECT state,
       count(*),
       max(now() - state_change) AS longest_in_state
FROM pg_stat_activity
GROUP BY state
ORDER BY count DESC;

-- idle connections sorted by how long they've been idle
SELECT pid, usename, application_name,
       now() - state_change AS idle_for,
       client_addr
FROM pg_stat_activity
WHERE state = 'idle'
ORDER BY idle_for DESC
LIMIT 20;
```

Fixes in order of preference:
1. **Add a connection pooler (PgBouncer in transaction mode).** This is the permanent fix. The pooler holds a small number of actual backend connections (e.g. 50) and multiplexes thousands of application connections onto them. Transaction-mode pooling works with stateless applications; session-mode pooling is required for apps that use `SET LOCAL`, `LISTEN/NOTIFY`, or temp tables.
2. **Set `idle_in_transaction_session_timeout`** to a reasonable value (e.g. `30s`). This terminates sessions that open a transaction and then do nothing — a common application bug.
3. **Set `idle_session_timeout`** (PG 14+) to terminate long-running idle sessions.
4. Raise `max_connections` — only as a short-term band-aid. Each additional slot costs ~10 KB in the procarray and lock table, and the scheduler overhead grows non-linearly.

```sql
-- emergency: terminate long idle-in-transaction sessions
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND now() - state_change > interval '5 minutes';
```

### Backend stuck (long-running query or lock wait)

```sql
-- all active backends older than 30 seconds
SELECT pid,
       now() - query_start    AS query_age,
       wait_event_type,
       wait_event,
       state,
       left(query, 100)       AS query
FROM pg_stat_activity
WHERE state != 'idle'
  AND query_start < now() - interval '30 seconds'
ORDER BY query_start NULLS LAST;

-- lock dependency graph: find the blocker chain
SELECT
  blocked.pid          AS blocked_pid,
  blocked.usename      AS blocked_user,
  left(blocked.query, 80) AS blocked_query,
  blocking.pid         AS blocking_pid,
  blocking.usename     AS blocking_user,
  left(blocking.query, 80) AS blocking_query
FROM pg_stat_activity AS blocked
JOIN pg_stat_activity AS blocking
  ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;
```

Terminate a specific backend safely:
```sql
SELECT pg_cancel_backend(pid);    -- SIGINT: kills query, preserves connection
SELECT pg_terminate_backend(pid); -- SIGTERM: kills query AND connection, rolls back txn
```

`pg_cancel_backend` only works while the backend is at an interrupt-check point. Most query operations check regularly, but a long COPY, a sort spill to disk, or a hash build may not respond immediately.

### Shared memory sizing problems

**`shared_buffers` too small** — the cache hit rate drops:

```sql
-- buffer hit ratio for all user tables
SELECT
  sum(heap_blks_hit)::numeric /
    nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0) AS hit_ratio
FROM pg_statio_user_tables;
-- healthy: > 0.97 for OLTP; lower is acceptable for data-warehouse workloads
```

Under 0.95 on a steady-state OLTP workload: increase `shared_buffers`. The guideline of 25% RAM applies to a dedicated server; a container or shared server warrants less.

**WAL buffers full** — backends stall waiting to write WAL:

```sql
SELECT name, setting, unit
FROM pg_settings
WHERE name IN ('wal_buffers', 'wal_writer_delay', 'commit_delay');
```

`wal_buffers = -1` (default) auto-sizes to 1/32 of shared_buffers, capped at 16 MB. If you have a high-concurrency write workload and see many `WALWrite` wait events, try `wal_buffers = 64MB`.

**Shared memory exhaustion** — if you try to start Postgres and it fails with `could not create shared memory segment`:

```bash
# check current POSIX shared memory limits
ipcs -lm           # System V limits (older kernels)
cat /proc/sys/kernel/shmmax    # maximum size of a single shared memory segment
cat /proc/sys/kernel/shmall    # total pages of shared memory system-wide

# inside the container:
docker exec dojo-pg sysctl kernel.shmmax kernel.shmall
```

In Docker, shared memory is limited by the `--shm-size` flag (default 64 MB). For any meaningful Postgres instance:
```bash
docker run -d --shm-size=256m --name dojo-pg -e POSTGRES_PASSWORD=dojo postgres:16-alpine
```

---

## Checkpoint

Before moving on, answer these without looking:

1. Name every background process and the one job each one owns. Which process calls `fsync`?
2. Where is the last checkpoint LSN stored, and how do you read it while the server is stopped?
3. What is the difference between `pg_cancel_backend` and `pg_terminate_backend` at the OS level (signal sent)?
4. A backend crashes mid-transaction. Does it take down other connections? Explain why.
5. Sketch the startup protocol: which message does the client send first, and what does BackendKeyData carry?
6. `pg_wal/` is consuming 40 GB. List three distinct causes.
7. A shared_buffers hit ratio of 0.82 is measured. List in order the things you'd investigate.
8. You have `max_connections = 500` and 480 connections in state `idle`. Raising `max_connections` to 1000 is not the right answer — explain why, and state what is.
9. What is XID wraparound, why is it catastrophic, and which autovacuum metric tracks how close you are?
10. The `extended query protocol` is said to prevent SQL injection at the protocol level. Explain the mechanism.

➡ Next: **MVCC & Transactions** — the heart of how Postgres achieves concurrency without locking reads.
