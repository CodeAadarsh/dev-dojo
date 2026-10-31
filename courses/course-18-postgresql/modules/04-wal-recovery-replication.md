# WAL, Recovery & Replication

> **Module 04 · Course 18** — The write-ahead log is the single most consequential data structure in PostgreSQL. Durability, crash recovery, point-in-time restore, streaming replication, and logical decoding all depend on it. Getting WAL wrong in production means data loss or unrecoverable downtime. This module explains how WAL works from the record level upward, and what every senior engineer should know before touching `wal_level`, `synchronous_commit`, or replication slots in production.

The write-ahead log (WAL) is a sequential append-only log of every change Postgres makes to the data directory. The fundamental guarantee: **a data page change is never written to the main data files before its corresponding WAL record has been flushed to disk.** If the server crashes mid-operation, recovery simply replays the WAL from the last checkpoint — the database arrives in a consistent state with no data loss for any committed transaction.

---

## Write-Ahead Logging

### The WAL contract

Before any backend modifies a shared_buffers page it must:

1. Construct a WAL record describing the change (old values and/or new values, depending on `wal_level`)
2. Write that record into the WAL buffer in shared memory
3. At `COMMIT`: flush the WAL buffer to disk — `walwriter` or the committing backend calls `XLogFlush` to ensure the WAL record is on stable storage before acknowledging the commit to the client

Only after the commit WAL record is durably on disk does the backend send `CommandComplete` to the client. This ordering is the definition of durability in the ACID sense.

The dirty shared_buffers page (the actual modified data file) can be flushed to disk later, lazily, by the bgwriter and checkpointer — because the WAL is already there. If the server crashes before the dirty page is written, recovery replays the WAL record and reconstructs the correct page content.

### WAL record structure

Each WAL record has a fixed-size header followed by resource-manager-specific data:

```
  XLogRecord header (24 bytes):
  ┌──────────────────────────────────────────────────────────┐
  │  xl_tot_len  (4 bytes) — total length of this record     │
  │  xl_xid      (4 bytes) — XID of the transaction, or 0   │
  │  xl_prev     (8 bytes) — LSN of previous record (chain)  │
  │  xl_info     (1 byte)  — resource manager info/flags     │
  │  xl_rmid     (1 byte)  — resource manager ID (heap, btree, etc.) │
  │  xl_crc      (4 bytes) — CRC32C checksum                 │
  └──────────────────────────────────────────────────────────┘
  Followed by: one or more block image headers + actual data
```

The **resource manager** (rmgr) identifies the subsystem that produced the record: `RM_HEAP` for heap inserts/updates/deletes, `RM_BTREE` for B-tree index operations, `RM_XLOG` for checkpoint records, `RM_SMGR` for file creation/truncation, and so on.

### LSN — Log Sequence Number

Every byte position in the WAL stream has a **Log Sequence Number**: a 64-bit integer that is a byte offset into the overall WAL stream. LSNs look like `0/1A8F000` (hexadecimal, `WAL_segment_number/byte_offset_within_segment`).

LSNs are monotonically increasing and are written into every heap page's `pd_lsn` field when that page is modified. This is used during recovery to avoid replaying WAL records that are already reflected in a page (idempotent replay).

```sql
-- current write LSN (furthest position written to WAL buffer)
SELECT pg_current_wal_lsn();

-- current flush LSN (furthest position flushed to disk)
SELECT pg_current_wal_flush_lsn();

-- WAL position of the last insert by this session
SELECT pg_current_wal_insert_lsn();

-- size of WAL generated between two LSNs
SELECT pg_size_pretty(pg_wal_lsn_diff('0/2000000', '0/1A8F000'));
```

### WAL segment files

WAL is stored in fixed-size segment files in `$PGDATA/pg_wal/`. Each segment is 16 MB by default (configurable at `initdb` time with `--wal-segsize`). Segment filenames encode the timeline ID, the high-order bytes, and low-order bytes of the LSN:

```
$PGDATA/pg_wal/
  000000010000000000000001   ← timeline=1, segment 0x000000000000001
  000000010000000000000002
  000000010000000000000003
  …
```

When a segment is full, the walwriter starts a new one. Old segments are either recycled (renamed to a future segment name) or removed, depending on:
- `wal_keep_size` — minimum amount of WAL to keep even if no one needs it
- Archive command — if `archive_command` is set, segments are kept until archiving succeeds
- Replication slots — slots keep WAL back to their `restart_lsn`

---

## full_page_writes

### Why they exist

When Postgres writes an 8 KB page to disk, the OS writes it in smaller units (typically 4 KB sectors). If the server crashes during a partial page write, half the page on disk will contain old data and half will be new data — a **torn page** that is unrecoverable by simple WAL replay because the WAL record assumes the old data was intact.

`full_page_writes = on` (the default and strongly recommended setting) causes Postgres to include the **entire 8 KB page image** in the WAL record the *first time a page is modified after a checkpoint*. Recovery can then always reconstruct the correct page by applying the full page image from WAL, regardless of what state the partially-written page is in.

```
Checkpoint happens at LSN A.

First modification to page P after checkpoint:
  WAL record = { full_page_image_of_P, changes_applied }
  Page is now "covered" by WAL — subsequent modifications only record deltas.

Server crashes during sector write.
Recovery from LSN A:
  Reads full page image from WAL — replaces the torn on-disk page
  Then applies subsequent WAL records as deltas
  Database is consistent.
```

### Performance impact of full_page_writes

FPWs increase WAL volume. The first write to each distinct page after each checkpoint writes a full 8 KB (possibly compressed by WAL compression, `wal_compression = on`). Workloads with many random writes generate far more WAL with FPWs on than off. Increasing `checkpoint_timeout` (longer intervals between checkpoints) reduces the proportion of writes that trigger FPWs.

```sql
SHOW full_page_writes;          -- should be on; turning it off risks data corruption
SHOW wal_compression;           -- lz4 or zstd compress FPWs with minimal CPU cost
-- set in postgresql.conf:
-- wal_compression = lz4       # PG 15+; reduces FPW WAL volume by 50-80%
```

### wal_level

`wal_level` controls how much information is included in WAL records:

| Level       | Contents | Minimum Use Case |
|-------------|----------|-----------------|
| `minimal`   | Enough for crash recovery only. Bulk operations (CREATE TABLE AS, COPY) are not WAL-logged individually. | Standalone servers with no replication, no PITR needed |
| `replica`   | Full logging for streaming and file-based replication. Default since PG 10. | Any standby replication setup |
| `logical`   | Everything in `replica` plus row-level info needed by logical decoding. | Logical replication, CDC with tools like Debezium |

Almost every production setup uses `replica` or `logical`. `minimal` is only appropriate for bulk-load performance tests where you don't need the data to survive a crash.

```sql
SHOW wal_level;
-- change requires restart:
-- ALTER SYSTEM SET wal_level = 'logical';
-- then: SELECT pg_reload_conf();  -- or restart for wal_level changes
```

---

## Checkpoints

A **checkpoint** is a consistent point in time at which all dirty shared_buffers pages have been flushed to disk and the position (LSN) has been recorded in `pg_control`. After a checkpoint, recovery can begin replaying WAL from that LSN without needing to redo any work that happened before it.

### Checkpoint mechanics

```
timeline:

  checkpoint at LSN X                         next checkpoint at LSN Y
       │                                              │
       │   dirty pages accumulate in shared_buffers   │
       │   WAL records accumulate in pg_wal/          │
       │                                              │
  ─────┼──────────────────────────────────────────────┼──────
       │                                              │
       ▼                                              ▼
  pg_control updated                           pg_control updated
  with LSN X                                   with LSN Y

  Crash recovery after a crash between X and Y:
  → Start from LSN X (read from pg_control)
  → Replay WAL from X to the end of written WAL
  → Database is at a consistent state with all committed transactions
```

The checkpointer writes a checkpoint WAL record at the start of the checkpoint process. This record contains the LSN where recovery should start. A second `REDOpoint` LSN is written — this is the LSN of the earliest WAL record that is still needed (some dirty pages may have been last modified before the checkpoint started).

### Checkpoint tuning

Too-frequent checkpoints (driven by `max_wal_size`) increase I/O. Too-infrequent checkpoints increase recovery time after a crash.

```sql
-- Check checkpoint frequency and I/O distribution
SELECT
  checkpoints_timed,
  checkpoints_req,                                        -- size-triggered (WAL grew too large)
  checkpoint_write_time / 1000.0 AS write_seconds,
  checkpoint_sync_time  / 1000.0 AS sync_seconds,        -- time spent in fsync
  buffers_checkpoint,
  buffers_clean,
  buffers_backend,
  maxwritten_clean
FROM pg_stat_bgwriter;

-- if checkpoints_req >> checkpoints_timed: max_wal_size is too small for your write rate
-- if checkpoint_sync_time is large: your storage fsync throughput is the bottleneck
```

Key parameters:
```sql
SHOW checkpoint_timeout;         -- default 5min; increase to 15-30min for write-heavy DBs
SHOW max_wal_size;               -- default 1GB; increase proportionally with checkpoint_timeout
SHOW checkpoint_completion_target;  -- default 0.9; how much of the timeout to spread writes over
```

### The checkpoint gap and recovery time

If `checkpoint_timeout = 30min` and the server crashes 29 minutes in, recovery must replay 30 minutes of WAL. This is typically fast (WAL replay is sequential I/O) but on very write-heavy workloads it can be significant. The tradeoff: longer checkpoints mean more I/O smoothing and less checkpoint overhead during normal operation, but longer recovery time after a crash.

---

## Crash Recovery

When Postgres starts after an unclean shutdown, it reads `pg_control` to find the most recent valid checkpoint and begins WAL replay from that point.

Recovery phases:
1. **Analysis** (PG doesn't have an explicit analysis phase like some other DBs; it starts replay immediately from the checkpoint)
2. **Redo**: Replay every WAL record from the redo point to the end of written WAL. For each record, check `pd_lsn` in the page — if the page's LSN is already >= the WAL record's LSN, the change is already reflected; skip. Otherwise, apply the change.
3. **End**: Write a new checkpoint at the end of recovery, switch to normal production mode.

```bash
# Start Postgres after a crash — it will notice the state in pg_control:
# "database system was not properly shut down; automatic recovery in progress"
# You'll see WAL replay in the logs:
# LOG:  starting point-in-time recovery to latest
# LOG:  restored log file "000000010000000000000005" from archive
# LOG:  redo starts at 0/50004F8
# LOG:  consistent recovery state reached at 0/5000568
# LOG:  redo done at 0/5001D68; oldest unflushed point is 0/5001C18
```

### pg_control states

The `Database cluster state` field in `pg_controldata` output:

| State | Meaning |
|-------|---------|
| `in production` | Server is running normally |
| `shut down` | Server was cleanly shut down (`pg_ctl stop`) |
| `shut down in recovery` | Standby was cleanly shut down |
| `in crash recovery` | Server is replaying WAL after a crash |
| `in archive recovery` | Standby is replaying WAL from archive |

If a standby's `pg_control` shows `in archive recovery` and you promote it to primary, its state moves to `in production` and its timeline ID increments.

---

## Streaming Replication

Streaming replication is the primary HA mechanism for PostgreSQL. A **primary** streams WAL records to one or more **standby** servers in real time. Standbys continuously replay the WAL — their heap and index files are kept in sync with the primary.

### Architecture

```
  PRIMARY                                        STANDBY(s)
  ┌───────────────────────────────┐              ┌───────────────────────────────┐
  │  backends write data          │              │  WAL receiver process         │
  │  WAL records generated        │              │    ← streams WAL from primary │
  │  walwriter flushes to pg_wal/ │              │  startup process replays WAL  │
  │                               │   WAL stream │    applies changes to pages   │
  │  WAL sender process (walsend) │──────────────►  read-only queries allowed   │
  │    reads pg_wal/ and streams  │   (TCP conn) │    (hot_standby = on)        │
  └───────────────────────────────┘              └───────────────────────────────┘
```

The **walsender** process on the primary reads WAL from `pg_wal/` (or from WAL buffer if recent enough) and streams it to the standby's **walreceiver** process. The standby's **startup process** reads from a local WAL buffer maintained by walreceiver and applies each record to the local data pages.

### Setting up streaming replication (production checklist)

On the primary:
```sql
-- wal_level must be at least 'replica'
ALTER SYSTEM SET wal_level = 'replica';

-- how many walsender processes to allow (one per standby)
ALTER SYSTEM SET max_wal_senders = 5;

-- retain WAL for standbys that temporarily disconnect
ALTER SYSTEM SET wal_keep_size = '512MB';

-- create a replication role
CREATE ROLE replicator LOGIN REPLICATION PASSWORD 'secret';
```

```
# pg_hba.conf on primary: allow replication connection from standby
host  replication  replicator  10.0.0.20/32  scram-sha-256
```

On the standby (after taking a base backup with `pg_basebackup`):
```
# postgresql.conf on standby:
primary_conninfo = 'host=10.0.0.10 port=5432 user=replicator password=secret application_name=standby1'
hot_standby = on
```

```bash
touch $PGDATA/standby.signal   # tells Postgres to start in standby mode
pg_ctl start
```

### Monitoring replication lag

```sql
-- on the primary: per-standby lag
SELECT
  application_name,
  state,
  sent_lsn,
  write_lsn,
  flush_lsn,
  replay_lsn,
  pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn))  AS total_lag,
  pg_size_pretty(pg_wal_lsn_diff(sent_lsn, flush_lsn))   AS flush_lag,
  sync_state
FROM pg_stat_replication
ORDER BY application_name;

-- on the standby: local lag
SELECT
  now() - pg_last_xact_replay_timestamp() AS replay_lag,
  pg_is_in_recovery()                     AS is_standby,
  pg_last_wal_receive_lsn()               AS received,
  pg_last_wal_replay_lsn()                AS replayed;
```

Replication lag has two components:
1. **Network / send lag**: `sent_lsn - write_lsn` — WAL generated but not yet received by standby
2. **Replay lag**: `write_lsn - replay_lsn` — WAL received but not yet applied to pages (can happen under heavy replay load or if the standby is paused)

---

## Replication Slots

A **replication slot** is a server-side bookmark that tracks how much WAL the consumer has received. The primary retains all WAL >= the slot's `restart_lsn`, even if no standby is currently connected.

```sql
-- create a physical replication slot for a standby
SELECT pg_create_physical_replication_slot('standby1_slot');

-- on the standby, reference it in primary_conninfo:
-- primary_slot_name = 'standby1_slot'

-- monitor slots
SELECT slot_name, slot_type, active, xmin, catalog_xmin,
       pg_size_pretty(
         pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
       ) AS retained_wal
FROM pg_replication_slots;
```

### The danger of unused replication slots

If a standby goes down and its slot is not dropped, the primary retains all WAL from the slot's `restart_lsn` forward. This can fill `pg_wal/` entirely and crash the primary.

```
pg_wal/ growing:
  standby1_slot  restart_lsn = 0/1000000  (set when standby last connected, 3 days ago)
  current LSN   = 0/A000000
  retained WAL  = ~9 × 16MB = 144MB per 16MB segment ← this could be GBs or TBs

primary runs out of disk → PANIC → database down
```

Operational rule: **always drop a replication slot when decommissioning a standby.** Set `max_slot_wal_keep_size` (PG 13+) as a safety valve:

```sql
-- fail the slot rather than let it accumulate unbounded WAL
ALTER SYSTEM SET max_slot_wal_keep_size = '10GB';
SELECT pg_reload_conf();
-- when pg_wal/ would exceed this, the slot is invalidated (error returned to standby)
-- better to have the standby error than the primary crash
```

---

## Synchronous vs Asynchronous Replication

`synchronous_commit` controls the durability guarantee for the committing transaction:

| Setting | Durability | Latency |
|---------|-----------|---------|
| `off` | May lose last few transactions after a crash (but *server* is safe; only recently committed transactions at risk) | Lowest (no WAL flush wait) |
| `local` (default) | Committed transactions survive a primary crash | Baseline (WAL flushed to primary disk) |
| `remote_write` | Committed transactions survive primary crash AND are on standby's OS buffer (but not necessarily fsynced) | + network RTT |
| `remote_apply` | Committed transactions are applied to standby's pages — readable from standby immediately | + apply latency |
| `on` | Same as `remote_apply`; synchronous_standby_names must match a connected standby | + apply latency |

```sql
SHOW synchronous_commit;        -- local by default

-- require synchronous commit to a specific standby:
ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (standby1, standby2)';
-- FIRST N means N standbys must confirm; remainder are async

-- per-transaction override (useful for non-critical writes):
BEGIN;
SET LOCAL synchronous_commit = off;
INSERT INTO analytics_events ...;
COMMIT;
-- this transaction may be lost if primary crashes, but that's acceptable for analytics
```

**`synchronous_commit = off` is not the same as disabling durability at the database level.** It only affects the commit acknowledgment — if the primary crashes and loses uncommitted WAL, only those recent asynchronous commits are lost. The database itself recovers correctly from the last durable WAL. This tradeoff is explicitly acceptable for high-throughput, loss-tolerant writes (event counters, analytics, audit logs where a few seconds of data loss is acceptable).

---

## Logical Decoding and Logical Replication

Physical (streaming) replication sends raw WAL bytes — it replicates the entire cluster bit-for-bit. **Logical decoding** interprets WAL records into a stream of row changes (INSERT/UPDATE/DELETE for each table), enabling:

- Replication to a different Postgres version or architecture
- Selective table replication
- Zero-downtime migrations
- Change data capture (CDC) for event streaming pipelines (Debezium, pglogical, etc.)

### How logical decoding works

With `wal_level = logical`, WAL records include enough information to reconstruct the before/after values of rows (not just the page-level diff). A **output plugin** (e.g. `pgoutput` built into Postgres, or `wal2json` from an extension) decodes the raw WAL into a human-readable or structured stream.

```sql
-- Create a logical replication slot
SELECT pg_create_logical_replication_slot('my_slot', 'pgoutput');

-- Peek at changes (non-destructive)
SELECT * FROM pg_logical_slot_peek_changes('my_slot', NULL, 10,
  'proto_version', '1',
  'publication_names', 'my_pub'
);

-- Consume changes (advances the slot)
SELECT * FROM pg_logical_slot_get_changes('my_slot', NULL, 10,
  'proto_version', '1',
  'publication_names', 'my_pub'
);
```

### Built-in logical replication (PG 10+)

Postgres has built-in logical replication using publications and subscriptions:

```sql
-- on the source (publisher):
ALTER SYSTEM SET wal_level = 'logical';
SELECT pg_reload_conf();   -- logical requires restart in some versions

CREATE PUBLICATION orders_pub FOR TABLE orders, order_items;

-- on the target (subscriber, a different Postgres instance):
CREATE SUBSCRIPTION orders_sub
  CONNECTION 'host=source-db port=5432 user=replicator password=secret dbname=mydb'
  PUBLICATION orders_pub;
```

The subscriber creates its own logical replication slot on the publisher. The `pg_stat_subscription` view shows the subscription status and lag:

```sql
SELECT subname, pid, relid::regclass, received_lsn, latest_end_lsn,
       latest_end_time,
       now() - latest_end_time AS lag
FROM pg_stat_subscription;
```

### Logical decoding for CDC

Tools like Debezium connect to Postgres as a logical replication client, read changes from a logical slot using the `pgoutput` or `wal2json` plugin, and publish them as events to Kafka. This is the standard pattern for keeping a data warehouse or Elasticsearch in sync with Postgres without using triggers or polling.

Key operational consideration: **logical replication slots are held open persistently**. If the CDC consumer stops, the slot retains WAL from its `restart_lsn` forward. A Debezium pod that crashes and isn't restarted for a week can fill your `pg_wal/`. Monitor `retained_wal` in `pg_replication_slots` and alert when it exceeds a threshold.

---

## Failover and Promotion

When the primary fails, a standby is promoted. In Postgres 12+ this is done with:

```bash
pg_ctl promote -D $PGDATA
# or: touch $PGDATA/promote (the trigger file approach, legacy)
```

Promotion causes:
1. The standby stops applying WAL from the primary
2. It writes a new timeline record to WAL (timeline ID increments)
3. It transitions from `in archive recovery` to `in production` state
4. It starts accepting read-write connections

After promotion, the old primary is no longer authoritative. Any transactions that were in-flight or asynchronously committed on the old primary and not yet replicated to the promoted standby are **lost** — this is the replication lag window at the moment of failure.

If the old primary comes back up, it must not be allowed to serve writes — it has a divergent timeline. It needs to be reconfigured as a standby pointing to the new primary, with a rewind using `pg_rewind`:

```bash
# Rewind the old primary to sync with the new primary's timeline:
pg_rewind --target-pgdata=$PGDATA \
          --source-server='host=new-primary port=5432 user=replicator ...' \
          --progress
# This replays enough WAL to bring the old primary's pg_control in sync with the new timeline.
```

`pg_rewind` is far faster than `pg_basebackup` for large databases — it only copies the changed blocks, not the entire data directory.

---

## Debugging: WAL & Replication

### Replication lag is growing

Immediate triage:
```sql
-- On primary: is the walsender running?
SELECT pid, usename, application_name, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag
FROM pg_stat_replication;

-- Is the standby receiving WAL?
-- On standby:
SELECT pg_is_in_recovery(),
       pg_last_wal_receive_lsn(),
       pg_last_wal_replay_lsn(),
       now() - pg_last_xact_replay_timestamp() AS replay_lag_seconds;
```

Causes of lag:
1. **Network bandwidth saturated** — the WAL stream volume exceeds link capacity. Reduce `wal_compression = on` or use a faster link.
2. **Standby I/O saturated** — replay requires writing to data pages; if the standby's I/O is slower than the primary's WAL generation rate, lag grows. Check `iostat` on the standby.
3. **Hot standby conflict** — a query on the standby conflicts with a WAL record being applied (e.g. a VACUUM record vs a long-running standby read). Postgres delays WAL application until the query finishes (up to `max_standby_streaming_delay`), causing replay lag. Long-running analytics queries on a hot standby are a common cause.

```sql
-- On standby: check for conflicts
SELECT pid, datname, now() - query_start AS age, query
FROM pg_stat_activity
WHERE wait_event = 'RecoveryConflictSnapshot';
```

Increase `max_standby_streaming_delay` to allow more lag before conflicts abort queries, or cancel queries aggressively to keep lag down.

### WAL bloat (pg_wal/ growing unboundedly)

```bash
du -sh $PGDATA/pg_wal/
ls -lh $PGDATA/pg_wal/ | wc -l    # number of segment files

# Ideal: (max_wal_size / wal_segment_size) files, e.g. 1GB / 16MB = ~64 files
# More than ~3× this indicates a problem
```

Diagnose:
```sql
-- 1. Check replication slots (most common cause)
SELECT slot_name, active, restart_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots
ORDER BY restart_lsn ASC;

-- 2. Check archiving (if archive_status/ has .ready files that aren't being archived)
-- ls $PGDATA/pg_wal/archive_status/

-- 3. Check pg_walfile_name for oldest needed WAL
SELECT pg_walfile_name(pg_current_wal_lsn()),
       pg_walfile_name(
         (SELECT min(restart_lsn) FROM pg_replication_slots)
       ) AS oldest_needed;
```

Fix options:
- Drop unused replication slots: `SELECT pg_drop_replication_slot('stale_slot');`
- Fix the broken archiver (check `archive_command` output in logs)
- Set `max_slot_wal_keep_size` to cap slot-driven WAL retention

### Failover gotchas

**Split-brain**: if the old primary continues accepting writes (e.g. VIP was not removed, or clients reconnect directly), you now have two primaries writing divergent timelines. The solution is a reliable fencing mechanism — a STONITH device, a VIP that only the current primary owns, or a Patroni/Stolon cluster manager that prevents the old primary from accepting connections by blocking its pg_hba.conf or controlling its process.

**Post-failover standby lag spike**: immediately after promotion, if other standbys are still pointed at the old primary, they need to be redirected to the new primary. In the window between promotion and standby reconfiguration, those standbys are not receiving WAL and their lag grows.

**pg_rewind requires `wal_log_hints = on` or checksums enabled** on the old primary to detect which data blocks diverged. If neither is set, `pg_rewind` falls back to copying every modified block determined by WAL scan (slower but functional).

```sql
SHOW wal_log_hints;
-- if off, add to postgresql.conf and restart:
-- wal_log_hints = on
```

**Timeline confusion**: after failover, the promoted standby has a new timeline ID. Other clients that cached the old timeline may see errors. Libpq drivers handle this transparently; some older tools do not. Verify with:
```sql
SELECT timeline_id FROM pg_control_checkpoint();
```

---

## Checkpoint

You're production-ready on this topic when you can answer:

1. State the write-ahead logging contract in one sentence: what must happen before a page change can go to the data file?
2. What is an LSN? What are the three distinct LSN values Postgres exposes via SQL, and what does each represent?
3. Why does `full_page_writes = on` exist? What failure scenario does it protect against?
4. Describe the three `wal_level` settings and when each is appropriate.
5. Walk through the checkpoint process step by step. At what LSN does recovery begin after a crash, and where is that LSN stored?
6. A standby's replay lag is 45 seconds and growing. Name three distinct root causes and the diagnostic command for each.
7. A replication slot has `restart_lsn` from 5 days ago and `active = false`. What will happen to `pg_wal/` and how do you fix it safely?
8. Explain `synchronous_commit = off`. Is it safe? When is it an acceptable tradeoff?
9. What is logical replication's advantage over physical (streaming) replication? What does `wal_level = logical` add to WAL records?
10. After a failover, the old primary restarts and tries to rejoin as a standby. What tool do you use and why can't you just point it at the new primary without that step?

➡ Next challenges: apply this knowledge against a real Postgres instance — `docker run -d --name dojo-pg -e POSTGRES_PASSWORD=dojo -p 55432:5432 postgres:16-alpine`.
