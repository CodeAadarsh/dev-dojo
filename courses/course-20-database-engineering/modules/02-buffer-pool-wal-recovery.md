# Buffer Pool, WAL & Crash Recovery

> **Module 02 · Course 20** — Your database can lose power at any instant. Yet when it comes back up, every committed transaction must be visible and every uncommitted one must be gone. This guarantee is not magic — it is a combination of three interlocking subsystems: the buffer pool (what's in memory), the write-ahead log (the durable audit trail), and the ARIES recovery algorithm (the replay procedure). Understand these three and you will never again be mystified by "how does Postgres recover?" or lose sleep over `fsync`.

This module goes deep enough that after reading it you could sketch a minimal crash-safe storage engine from scratch — which is exactly the level of understanding you need to debug production incidents involving corrupted data, recovery time spikes, or "it says it committed but the row is gone."

---

## The Buffer Pool: RAM as a Cache for Disk Pages

Every page read from disk lives in the **buffer pool** (InnoDB calls it the buffer pool; Postgres calls it the shared buffer cache). It is a fixed-size region of memory — typically 25–50% of total RAM on a dedicated database host.

```
┌─────────────────────────────── buffer pool (e.g. 4 GB) ─────────────────────────────────┐
│                                                                                          │
│  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐               │
│  │  buf 0 │  │  buf 1 │  │  buf 2 │  │  buf 3 │  │  buf 4 │  │  buf 5 │  ...          │
│  │        │  │ page 7 │  │ page 42│  │ page 99│  │        │  │ page 3 │               │
│  │ (free) │  │ clean  │  │  DIRTY │  │  DIRTY │  │ (free) │  │ clean  │               │
│  └────────┘  └────────┘  └────────┘  └────────┘  └────────┘  └────────┘               │
│                                                                                          │
│  Page table: page_id → buffer frame number (hash map in memory)                         │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

When a transaction needs page 42:

1. Look up page 42 in the buffer pool **page table** (a hash map: page_id → frame).
2. If found (cache hit) — pin the frame, read from memory. No disk I/O.
3. If not found (cache miss) — find a victim frame to evict, write it back to disk if dirty, then read page 42 from disk into that frame.

The engine tracks a **pin count** per frame: a pinned frame cannot be evicted. A transaction pins every page it is actively using.

### Eviction Policies

When the buffer pool is full and a new page must be brought in, an eviction policy picks the victim.

**LRU (Least Recently Used).** Evict the frame that has gone the longest without being accessed. Maintains a doubly-linked list ordered by access time. Classic but suffers from "scan pollution": a full-table sequential scan touches every page once, thrashing the entire LRU list and evicting hot pages that were working well.

**Clock sweep (Postgres default, also called Clock or Second-Chance LRU).** Each frame has a "usage count" (Postgres uses a 5-bit counter). On access, the counter is incremented up to a cap. The eviction clock hand sweeps the buffer pool; frames with usage > 0 are decremented (given a second chance). The first frame with usage = 0 is evicted.

```
Clock sweep example (simplified, 3 frames):

State: [frame0: A, usage=3] [frame1: B, usage=1] [frame2: C, usage=0]
Need to evict one.

Hand at frame0: usage=3 > 0 → decrement to 2, skip.
Hand at frame1: usage=1 > 0 → decrement to 0, skip.
Hand at frame2: usage=0 → EVICT frame2 (page C).
```

Clock sweep is O(1) amortized and resists scan pollution better than strict LRU because repeated access increments the counter, making heavily-used pages harder to evict.

**InnoDB's LRU with young/old sublists.** InnoDB divides its LRU list into a "young" (hot, 5/8 of pool) and "old" (cold, 3/8) section. New pages enter the middle (old head). If accessed again within `innodb_old_blocks_time` milliseconds, they graduate to the young list. This makes full-table scans populate only the old section, protecting the young section from pollution.

---

## Dirty Pages and the Steal/No-Force Policy

A **dirty page** is a buffer frame whose in-memory content has been modified but not yet written to disk. The critical design question for crash recovery is:

> Can we evict a dirty page before its transaction commits? And must we flush dirty pages when a transaction commits?

These two choices define the **steal/no-force** policy matrix:

| Policy | Meaning | Consequence |
|--------|---------|-------------|
| **Steal** | Dirty pages of uncommitted transactions CAN be written to disk | Need UNDO log to roll back if the transaction aborts |
| **No-Steal** | Dirty pages must stay in memory until commit | Simpler recovery but buffer pool must be large enough to hold all dirty pages of active transactions |
| **Force** | All dirty pages MUST be flushed to disk at commit | Recovery never needs to redo committed changes — but commits become synchronous I/O, killing write throughput |
| **No-Force** | Dirty pages need NOT be written to disk at commit | Need REDO log to replay committed changes that hadn't been flushed |

**The dominant choice in production systems: Steal + No-Force.**

This is what Postgres, MySQL, SQL Server, and Oracle all use. It means:
- A page modified by an uncommitted transaction can be evicted to make room (Steal). Recovery must be able to undo this.
- When a transaction commits, we do *not* flush its dirty pages to disk (No-Force). Commits are fast. Recovery must be able to redo committed-but-unflushed changes.

The mechanism that makes both safe is the **Write-Ahead Log**.

---

## Write-Ahead Log (WAL)

The WAL is an append-only log file on disk. Before any page is modified in the buffer pool, a log record describing that modification is written to the WAL. "Write-ahead" means the log goes first.

```
WAL file (sequential on disk):
┌───────┬───────┬───────┬───────┬───────┬───────┬───────┬───────┐
│ LSN 1 │ LSN 2 │ LSN 3 │ LSN 4 │ LSN 5 │ LSN 6 │ LSN 7 │  ...  │
│ BEGIN │UPDATE │UPDATE │ BEGIN │UPDATE │COMMIT │COMMIT │       │
│ Txn A │page 7 │page 9 │ Txn B │page 7 │ Txn A │ Txn B │       │
└───────┴───────┴───────┴───────┴───────┴───────┴───────┴───────┘
LSN = Log Sequence Number (monotonically increasing, 64-bit integer in Postgres)
```

Each log record contains:
- **LSN** — position in the log (Postgres: byte offset from start of WAL)
- **Transaction ID** — which transaction produced this record
- **Type** — BEGIN, COMMIT, ABORT, UPDATE, DELETE, INSERT
- **Page ID + before-image (UNDO data)** — what the page looked like before the change
- **After-image (REDO data)** — what the page looks like after the change

The two WAL rules that make recovery possible:

1. **WAL Rule (for No-Force / Steal):** Before a dirty page is evicted to disk, all WAL records for that page up to its current LSN must already be on disk. This ensures we have the REDO log to replay the page's changes after a crash.
2. **Commit Rule:** Before a transaction is considered committed, its COMMIT log record must be flushed to disk. Once the commit record is on stable storage, the transaction survives any subsequent crash.

### LSN on Pages

Every page in the buffer pool carries the LSN of the last WAL record that modified it — called `pageLSN`. When the engine evaluates whether to evict a dirty page, it checks:

```
if (pageLSN > flushedUpToLSN):
    flush WAL up to pageLSN first, then write page to disk
```

This guarantees the WAL rule is never violated.

### WAL Flushing

WAL records are buffered in a small in-memory **WAL buffer** before being written to the WAL file. The buffer is flushed:
- When a transaction COMMITs (synchronously, for the commit durability guarantee)
- When the WAL buffer is full
- Periodically by a background process (Postgres: `wal_writer`)

The commit path in Postgres:

```
1. Append COMMIT record to WAL buffer
2. fdatasync() the WAL file segment  ← the expensive part
3. Return success to the client
```

`fdatasync` blocks until the kernel's write cache is flushed to stable storage. On a spinning disk this is 5–15ms of latency. On NVMe with a battery-backed write cache it is ~100µs. This single call is often the bottleneck for commit throughput.

**Group commit.** Postgres groups multiple concurrent commits into one `fdatasync`. If 100 transactions commit within the same wal_writer tick, all 100 get their commit record on disk with a single fsync. This is why commit throughput can be much higher than 1 / fsync_latency: on NVMe doing 0.1ms fsyncs, group commit can achieve thousands of commits/second.

---

## ARIES: The Recovery Algorithm

**ARIES (Algorithm for Recovery and Isolation Exploiting Semantics)** is the recovery protocol at the heart of most commercial and open-source databases (IBM DB2, SQL Server, Postgres, MySQL). Published by Mohan et al. in 1992, it is the textbook answer to "how do you recover a steal/no-force buffer pool after a crash?"

ARIES recovery proceeds in three passes in this exact order:

```
Crash occurs at point X in the WAL:

WAL: [BEGIN A] [UPD pg7 Txn-A] [BEGIN B] [UPD pg9 Txn-A] [COMMIT A] [UPD pg7 Txn-B] ... CRASH

Pass 1 — ANALYSIS   ──▶  What was in the buffer pool at crash time?
Pass 2 — REDO       ──▶  Replay all changes from the last checkpoint.
Pass 3 — UNDO       ──▶  Roll back every uncommitted transaction.
```

### Pass 1: Analysis

Start from the **last checkpoint** in the WAL (checkpoints are discussed below). Walk forward to the crash point.

Build two tables:
- **Dirty Page Table (DPT):** `{page_id → recLSN}` — the LSN of the first log record that made this page dirty since the last checkpoint. This is the earliest LSN from which redo must apply to that page.
- **Transaction Table (ATT / Active Transaction Table):** `{txn_id → lastLSN, status}` — the last LSN written by each in-flight transaction and whether it committed or was still running at crash time.

Any transaction with a COMMIT log record before the crash is marked "to be redone." Any without a commit is marked "to be undone."

### Pass 2: Redo

Start from the **minimum recLSN in the DPT** (the earliest any dirty page was first modified). Walk forward to the crash point, replaying every log record.

For each UPDATE record, apply the after-image to the page **only if**:
- The page is in the DPT (it was dirty at crash time, meaning it might not have been flushed), AND
- The page's on-disk LSN is less than the log record's LSN (the change hasn't been applied yet — it hasn't been flushed since the log was written).

This condition makes redo **idempotent**: if a page was flushed *after* the log record but before the crash, the on-disk page already has the change, and redo skips it rather than applying it twice.

After redo pass, the database is in the state it was in at the moment of the crash — including any pages modified by *uncommitted* transactions (because they were dirty and stolen to disk). This is why the undo pass follows.

### Pass 3: Undo

Walk the ATT. For every transaction that was still in-progress at crash time (no COMMIT record), undo its changes in **reverse LSN order** — applying the before-image of each update.

ARIES uses **Compensation Log Records (CLRs)** for undo. When you undo log record LSN 500, you write a CLR at the end of the WAL saying "I undid LSN 500." This is crucial: if the system crashes *again during recovery*, the redo pass will see the CLR and skip re-undoing it. CLRs make undo restartable.

```
Undo trace (simplified):

ATT after analysis: {Txn-B: lastLSN=6, status=in-progress}

Undo Txn-B:
  Read LSN 6: UPD pg7 Txn-B  →  apply before-image to pg7
  Write CLR(LSN=7, undoes=6, prevUndoLSN=none)
  No more undo records for Txn-B → write ABORT record.
```

The undo pass completes, and the database is consistent: committed transactions are visible, uncommitted ones are gone.

---

## Checkpoints

Without checkpoints, analysis and redo would have to scan the entire WAL from the beginning of time. A **checkpoint** periodically records a consistent snapshot:

1. Flush all dirty pages from the buffer pool to disk (or just write their page IDs — see "fuzzy checkpoint").
2. Write a CHECKPOINT log record to the WAL containing the current ATT and DPT.
3. On recovery, analysis starts from this checkpoint, not from the WAL origin.

**Sharp checkpoint (MySQL `innodb_fast_shutdown=0`-style):** Flush *all* dirty pages before writing the checkpoint record. Recovery becomes trivial: redo starts from the checkpoint LSN, analysis is minimal. But the flush is expensive — on a busy system with 100 GB of dirty data, a sharp checkpoint takes minutes and hammers I/O.

**Fuzzy checkpoint (Postgres, InnoDB in normal mode):** Write the checkpoint record immediately with the current DPT, then begin flushing dirty pages in the background. The checkpoint record says "start recovery from LSN X, and here are the dirty pages we intend to flush." Recovery still needs to redo from X, but dirty pages flush continuously without blocking writes.

Postgres calls its background checkpointer the `checkpointer` process. The interval is controlled by `checkpoint_timeout` (default 5 minutes) and `max_wal_size` (how much WAL can accumulate before a checkpoint is forced). A checkpoint that takes too long increases recovery time after a crash.

```sql
-- See checkpoint statistics in Postgres
SELECT checkpoints_timed, checkpoints_req, checkpoint_write_time, checkpoint_sync_time,
       buffers_checkpoint, buffers_clean, buffers_backend
FROM pg_stat_bgwriter;
```

`buffers_checkpoint` = pages written by the checkpointer (good, background).
`buffers_backend` = pages written by backend query processes (bad, means checkpointer can't keep up and queries are doing their own I/O).

---

## fsync and the Durability Contract

`fsync` (or `fdatasync`) is the system call that instructs the OS to flush its write-back cache to the physical storage device. The WAL commit durability guarantee **depends entirely on fsync doing what it promises**.

In most configurations:
```
commit path:
  write COMMIT record to WAL buffer
  write WAL buffer to OS page cache
  fdatasync(wal_fd)              ← blocks until data reaches durable storage
  return "committed" to client
```

If `fsync` returns success, the data is on stable storage. If the system crashes after this return, ARIES redo will replay the committed transaction.

### The fsync Lie Problem

In 2018–2019, the Linux kernel had a well-known bug: if `fsync` failed (e.g., due to a background write-back error), subsequent `fdatasync` calls on the same fd could return success even though data had not been flushed. PostgreSQL had additional exposure: it marked pages as clean in its buffer pool even on `fsync` error, so on restart, it would not try to re-flush those pages — leading to silent data loss.

This was the subject of the infamous "PostgreSQL fsync error handling" CVE (CVE-2018-1058-adjacent, and the broader Linux discussion). The fix: Postgres now marks a dirty page as needing re-flush on any `fsync` failure and raises a PANIC to restart, forcing redo.

**Takeaway:** `fsync` returning success is a contract. The kernel and firmware must honor it. On cloud VMs, most providers use write-through caches by default for this reason. On bare metal with hardware RAID controllers, ensure the battery-backed write cache (BBWC) is healthy — its loss can cause silent writes-not-persisted under load.

### Testing Durability with `pg_test_fsync`

Postgres ships a utility to measure fsync latency across different strategies:

```bash
pg_test_fsync -s 5   # test each strategy for 5 seconds
```

Output shows MB/s for `fdatasync`, `fsync`, `open_sync`, `open_datasync`. On NVMe you will see 1000+ MB/s; on a network-attached EBS volume you may see 30–100 MB/s. This directly tells you your maximum synchronous commit throughput.

---

## Debugging: Crash Recovery in Practice

### Lost Writes After Crash (Postgres)

**Symptom:** After an unclean shutdown, rows that were definitely committed are missing.

**Diagnosis path:**

1. Check that `wal_level` was not set to `minimal` with `archive_command` or replication disabled — `minimal` WAL does not log enough to recover from a crash in some operations:
   ```sql
   SHOW wal_level;   -- should be 'replica' or 'logical' in production
   ```

2. Check `synchronous_commit`:
   ```sql
   SHOW synchronous_commit;   -- 'off' means commits return before WAL flush
   ```
   `synchronous_commit = off` trades durability for throughput — up to `wal_writer_delay` (default 200ms) of committed transactions can be lost on crash. This is a *documented* trade-off, not a bug, but production teams often forget it is enabled.

3. If `synchronous_commit = on`, the problem is likely an fsync lie or a filesystem/volume misconfiguration. Check `dmesg` for I/O errors at crash time. Check if the filesystem was mounted with `nobarrier` or `data=writeback`.

### Recovery Taking Too Long (Postgres)

**Symptom:** After a crash, Postgres takes 10+ minutes to come back up.

**Cause:** The redo pass must replay WAL from the last checkpoint to the crash point. A large `max_wal_size` means the last checkpoint is far behind.

**Diagnosis:**
```bash
# Check checkpoint distance at runtime
SELECT pg_current_wal_lsn() - checkpoint_lsn AS wal_bytes_since_checkpoint
FROM pg_control_checkpoint();

# Or from pg_stat_bgwriter, correlate checkpoint intervals with wal written
SELECT checkpoints_timed, buffers_checkpoint
FROM pg_stat_bgwriter;
```

**Fix:** Reduce `max_wal_size` or `checkpoint_timeout` to force more frequent checkpoints. This increases I/O during normal operation but reduces recovery time. The trade-off: on a write-heavy system, more frequent checkpoints mean more background I/O.

### fsync Lies / EIO on Volume (All engines)

If your cloud provider's EBS volume is having issues, you may see:

```
PANIC:  could not write to file "pg_wal/000000010000000000000001": No space left on device
PANIC:  fsync failed for block 0 in file base/16384/1259: Input/output error
```

Postgres panics and refuses to start (or forcibly restarts in crash recovery mode) rather than risk silent data loss. This is the correct behavior. Do not try to disable it.

**Recovery path:**
1. Verify the volume is healthy at the OS level: `dmesg | grep -i 'io error'`
2. If the volume is clean, check for filesystem corruption: `fsck -n /dev/sdX`
3. Restore from backup rather than trying to manually reconstruct WAL.

### Diagnosing Slow Commits (High WAL Flush Latency)

If p99 commit latency is high, the bottleneck is almost always the `fdatasync` on the WAL segment. Profile it directly:

```bash
# Option 1: strace a backend process
strace -p <pid> -e fdatasync,fsync -T 2>&1 | grep -E 'fdatasync|fsync'
# → fsync(8, 0x7f...) = 0 <0.012345>  ← 12ms per fdatasync

# Option 2: pg_test_fsync utility
pg_test_fsync --secs-per-test 5
# → Comparing file sync methods using one 8kB write:
#    open_datasync        5432.35 ops/sec     0.184 msecs/op
#    fdatasync            4891.17 ops/sec     0.204 msecs/op
```

If `fdatasync` shows > 1ms consistently, consider:
- Moving WAL to a separate volume (WAL is sequential writes; data files are random)
- Using a WAL-optimized storage class (io2 on AWS, Premium SSD on Azure)
- Enabling `synchronous_commit = local` if you have a replica — commits only wait for the local WAL flush, not the replica's ack

### WAL Segmentation and Log Shipping

WAL is not a single file. Postgres splits it into 16 MB segments named by a 24-hex-character filename:

```
pg_wal/
  000000010000000000000001   ← timeline 1, segment 1
  000000010000000000000002
  000000010000000000000003
  ...
```

WAL archiving (for base backup + point-in-time recovery) copies completed segments to an archive location before Postgres removes them:

```
# postgresql.conf
wal_level = replica          # must be >= replica to archive
archive_mode = on
archive_command = 'cp %p /mnt/wal-archive/%f'   # %p = path, %f = filename
```

**WAL retention and disk pressure.** With replication slots (a replica that falls behind), Postgres will retain WAL segments indefinitely until the replica catches up. An offline replica with a replication slot is the #1 cause of `pg_wal` directory growing without bound and filling the disk:

```sql
-- Check replication slot lag
SELECT slot_name, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag,
       active
FROM pg_replication_slots;

-- Drop a stale slot that is holding WAL (only if the replica is decommissioned)
SELECT pg_drop_replication_slot('stale_replica_slot');
```

Set `max_slot_wal_keep_size` (Postgres 13+) to limit WAL retained per slot:

```
max_slot_wal_keep_size = 10GB   # slot is invalidated rather than holding >10 GB
```

---

## Checkpoint

You are ready to proceed when you can, without notes:

1. Describe the buffer pool's page table and explain what "pin count" prevents.
2. Explain clock-sweep eviction and why it is more scan-resistant than strict LRU.
3. Define steal and no-force and explain why their combination requires both UNDO and REDO log.
4. Write the two WAL rules that govern when dirty pages may be written to disk and when a transaction may be marked committed.
5. Trace the ARIES three passes (Analysis, Redo, Undo) on a simple crash scenario: two transactions, one committed before crash, one in-progress.
6. Explain what a CLR is and why it makes ARIES restartable during undo.
7. Compare sharp vs fuzzy checkpoints: which is safer? Which is more write-friendly?
8. Describe the `synchronous_commit = off` trade-off in one sentence and when it is acceptable.
9. Explain the fsync-lie vulnerability and how Postgres's current behavior (PANIC on fsync error) is the correct response.

➡ Next: **Module 03 — The Transaction Model: ACID & Isolation** — having crash safety, now you need to understand what "correct" means when multiple transactions run concurrently.
