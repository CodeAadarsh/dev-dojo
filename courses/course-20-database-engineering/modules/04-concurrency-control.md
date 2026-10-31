# Concurrency Control

> **Module 04 · Course 20** — Module 03 defined what "correct concurrent execution" means — the anomalies and isolation levels. This module explains the *machinery* that enforces those guarantees. There are two dominant families: lock-based (2PL) and version-based (MVCC). Every production database uses one or a hybrid of both. After this module you will be able to read a deadlock graph, explain why Postgres VACUUM exists, tune lock granularity, and diagnose a long-transaction version bloat incident.

This is the module that turns abstract "isolation" into concrete engine behavior: row locks, lock wait graphs, version chains, garbage collection, and the reason a long-running transaction on a write-heavy Postgres table can silently inflate your disk usage by 10×.

---

## Two-Phase Locking (2PL)

Two-phase locking is the classical lock-based approach to achieving isolation. The core rule:

> A transaction must acquire all locks before releasing any lock.

This creates two distinct phases:

```
Transaction lifetime:
                 growing phase              shrinking phase
                 ┌────────────────────┐     ┌──────────────────────┐
                 │ acquire locks      │     │ release locks        │
                 │ (never release yet)│     │ (never acquire new)  │
                 └────────────────────┘     └──────────────────────┘
  BEGIN ──────────────────────────────────────────────────────── COMMIT/ABORT
                                            ▲
                                       lock point
```

The "lock point" is when the transaction holds its maximum set of locks. No new locks can be acquired after the first release.

**Why does this ensure isolation?** Suppose T1 holds a write lock on row R. T2 wants to read R. T2 must wait. This prevents T2 from reading R until T1 has committed (or aborted). Because T1 cannot release any lock until after the lock point, and the lock point precedes commit, T2 only ever sees committed data.

### Strict 2PL

Strict 2PL (S2PL, also called "rigorous 2PL") is the dominant practical variant:

> Hold all write locks until after COMMIT or ABORT.

In standard 2PL, you could release a write lock in the shrinking phase before commit — this risks cascading aborts (T2 reads T1's unlocked write, T1 aborts, T2 must also abort). Strict 2PL prevents this by keeping write locks held until transaction end.

Almost every production database uses strict 2PL for write locks. InnoDB uses strict 2PL. Oracle uses strict 2PL for writes and releases read locks early.

### Lock Modes

A single "lock" can have multiple modes with a compatibility matrix:

```
Lock Compatibility Matrix (rows: held, columns: requested):

           IS    S    IX    X    SIX
     IS  │  ✓  │  ✓  │  ✓  │  ✗  │  ✓
      S  │  ✓  │  ✓  │  ✗  │  ✗  │  ✗
     IX  │  ✓  │  ✗  │  ✓  │  ✗  │  ✗
      X  │  ✗  │  ✗  │  ✗  │  ✗  │  ✗
    SIX  │  ✓  │  ✗  │  ✗  │  ✗  │  ✗

✓ = compatible (both can be held simultaneously)
✗ = incompatible (second requester must wait)

IS  = Intent Shared    (intend to take S locks on rows below)
S   = Shared           (read lock)
IX  = Intent Exclusive (intend to take X locks on rows below)
X   = Exclusive        (write lock)
SIX = Shared + Intent Exclusive
```

Intent locks (IS, IX) are used at higher granularity levels (table) to indicate that lower-level (row) locks are being acquired without having to scan the entire table for conflicting locks.

### Granularity Hierarchy

Lock granularity is a performance dial:

```
Coarsest (low concurrency, low overhead):
  Database lock
  Table lock
  Page lock
  Row lock           ← typical default for OLTP
Finest (high concurrency, high overhead):
  Attribute lock     ← rarely implemented
```

**Row-level locks** are what Postgres and InnoDB use for DML. Table-level locks are used for DDL (`ALTER TABLE`) and explicit `LOCK TABLE` statements.

A common performance trap: a long `UPDATE` that holds row locks on thousands of rows will block all other writes to those rows for its entire duration. Batch updates in chunks:

```sql
-- Bad: holds X locks on all 1 million rows until commit
UPDATE orders SET status = 'archived' WHERE created_at < '2022-01-01';

-- Better: batches of 10,000, each with a short lock hold
DO $$
DECLARE
  rows_affected INT;
BEGIN
  LOOP
    UPDATE orders SET status = 'archived'
    WHERE id IN (
      SELECT id FROM orders WHERE status != 'archived'
        AND created_at < '2022-01-01' LIMIT 10000
    );
    GET DIAGNOSTICS rows_affected = ROW_COUNT;
    COMMIT;
    EXIT WHEN rows_affected = 0;
  END LOOP;
END $$;
```

---

## Deadlocks

A deadlock occurs when two (or more) transactions are each waiting for a lock held by the other.

```
Deadlock example:

T1 holds: X lock on row A
T2 holds: X lock on row B

T1 requests: X lock on row B  → WAITS for T2
T2 requests: X lock on row A  → WAITS for T1

Wait-for graph:
    T1 ──waiting──▶ T2
    T2 ──waiting──▶ T1
         ↑ cycle = deadlock
```

Deadlocks are inevitable in any system with multiple lock types and multiple concurrent transactions. The engine handles them by detecting the cycle and aborting one victim:

```
ERROR:  deadlock detected
DETAIL: Process 12345 waits for ShareLock on transaction 67890;
        blocked by process 98765.
        Process 98765 waits for ShareLock on transaction 12345;
        blocked by process 12345.
HINT:   See server log for query details.
```

Postgres detects deadlocks via a **background deadlock detector** that runs after a lock wait exceeds `deadlock_timeout` (default 1 second). This is intentional: most lock waits resolve quickly without a cycle, so running deadlock detection on every wait would be too expensive. The 1-second wait before detection means a deadlock costs at least 1 second.

### Deadlock Detection: The Wait-For Graph

The engine maintains a **wait-for graph**: nodes are transactions, edges are "T1 is waiting for a lock held by T2." A cycle in this graph is a deadlock.

```
Wait-for graph:
  T1 ──▶ T2 ──▶ T3 ──▶ T1   (cycle: deadlock involving T1, T2, T3)
  T4 ──▶ T5               (no cycle: T4 just waiting for T5 to finish)
```

Postgres uses a depth-first search to detect cycles. When found, it aborts the transaction with the smallest amount of work done (heuristic: the one that minimizes redo), surfacing it as a `40P01` serialization error.

### Deadlock Prevention (Application Patterns)

Application-level deadlock prevention is preferable to relying on detection:

**1. Consistent lock ordering.** If all transactions acquire locks in the same order, cycles cannot form.

```python
# Transfers: always lock lower account ID first
def transfer(conn, from_id, to_id, amount):
    if from_id > to_id:
        from_id, to_id = to_id, from_id  # swap to ensure consistent order
    with conn.transaction():
        conn.execute("SELECT 1 FROM accounts WHERE id=$1 FOR UPDATE", min_id)
        conn.execute("SELECT 1 FROM accounts WHERE id=$1 FOR UPDATE", max_id)
        # ... rest of transfer
```

**2. Minimize lock hold time.** Do all non-database work (HTTP calls, file I/O, business logic) *outside* transactions. The transaction should be as short as possible.

**3. Avoid user interaction inside transactions.** A transaction waiting on a user to click "confirm" holds locks for seconds. Move the database work after the user confirms.

**4. Use `SELECT ... FOR UPDATE SKIP LOCKED`.** For queue-like patterns where any pending row is acceptable:

```sql
-- Each worker grabs one job without blocking others
SELECT id, payload FROM jobs WHERE status='pending'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;
```

`SKIP LOCKED` skips rows locked by other transactions rather than waiting, eliminating the possibility of lock-order deadlocks in producer-consumer patterns.

---

## MVCC: Multi-Version Concurrency Control

MVCC is the alternative to lock-based concurrency for reads. The core idea:

> Instead of locking rows for reads, keep multiple versions of each row. Readers see the version consistent with their snapshot; writers create new versions without blocking readers.

This is why Postgres can have a long-running `SELECT` for a report run while concurrent `INSERT`/`UPDATE`/`DELETE` proceed without waiting.

### Row Versions in Postgres

Every row in a Postgres heap page carries two hidden system columns:

```
Tuple header (23 bytes):
  xmin  — transaction ID that inserted this row version (made it "live")
  xmax  — transaction ID that deleted this row version (or 0 = still live)
  ctid  — pointer to the current version (self-referential if no newer version)
  ...
```

```
Example: updating a row.

Initial state:
┌──────────────────────────────────────────────────┐
│ page 7, slot 3 │ xmin=100, xmax=0,  data='Alice' │  ← current live version
└──────────────────────────────────────────────────┘

T200 executes UPDATE SET name='Alicia':
┌──────────────────────────────────────────────────┐
│ page 7, slot 3 │ xmin=100, xmax=200, data='Alice' │  ← old version (dead after T200 commits)
└──────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────┐
│ page 7, slot 4 │ xmin=200, xmax=0,   data='Alicia'│  ← new version (live after T200 commits)
└──────────────────────────────────────────────────┘
```

A reader with snapshot T=150 (started before T200) will see the `xmin=100, xmax=200` version as live (because xmin=100 ≤ 150 and xmax=200 > 150). A reader with snapshot T=250 sees the new version.

**No read locks needed.** Writers never block readers; readers never block writers. Lock contention is limited to write-write conflicts.

### Visibility Rules

Postgres determines whether a tuple is visible to a snapshot at transaction ID `snap`:

```
Visible if:
  xmin < snap AND xmin.status == COMMITTED      (inserted by a committed txn before snap)
  AND (xmax == 0 OR xmax > snap OR xmax.status == ABORTED)  (not deleted, or deleted after snap)
```

The transaction ID comparison is done against a **snapshot** that records: `xmin` (oldest active txn), `xmax` (next assigned txn ID), and `xip` (list of currently active transaction IDs). This is how Postgres reads the "at the time T started, which txns were committed?" state.

---

## MVCC Garbage Collection (Vacuum)

MVCC's downside: old row versions accumulate. Every UPDATE leaves a dead tuple behind. Every DELETE leaves a dead tuple. Without cleanup, pages fill with dead tuples, making scans slower and wasting disk.

**Postgres VACUUM** removes dead tuples from pages and makes their space available for reuse. It does NOT return space to the OS by default — it marks pages as available for new tuples. `VACUUM FULL` rewrites the entire table to a compact form but locks the table exclusively.

```
Before VACUUM (page with dead tuples):
┌────────────────────────────────────────────────┐
│ slot[0]→tuple(dead) │ slot[1]→tuple(live) │ slot[2]→tuple(dead) │ free space │
└────────────────────────────────────────────────┘

After VACUUM:
┌────────────────────────────────────────────────┐
│ slot[0]→(available) │ slot[1]→tuple(live) │ slot[2]→(available) │ more free │
└────────────────────────────────────────────────┘
```

VACUUM also reclaims transaction IDs used by old transactions (transaction ID wraparound prevention — Postgres uses 32-bit transaction IDs, and after ~2 billion transactions, IDs wrap around, which would make old data appear "in the future"). `autovacuum` handles this automatically, but a long-running transaction can block it.

### The Long Transaction Vacuum Bloat Disaster

The most insidious MVCC performance problem in production Postgres:

```
Scenario:
  T1 starts at snapshot xid=5000 (long-running report, runs for 2 hours)
  
  During those 2 hours, the orders table receives 10 million updates.
  
  Each update creates a new row version.
  Each old row version has xmax > 5000 (the long transaction's snapshot).
  
  VACUUM cannot remove those old versions because T1 might still read them.
  
  Result: 10 million dead tuples accumulate, table size grows 2-3×, index scans
  slow down because they must skip dead tuples, and eventually autovacuum
  starts thrashing trying to clean up.
```

**Diagnosis:**

```sql
-- Find long-running transactions
SELECT pid, now() - xact_start AS duration, query, state
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY duration DESC;

-- Find oldest transaction holding up vacuum
SELECT age(relfrozenxid), relname
FROM pg_class
WHERE relkind = 'r'
ORDER BY age(relfrozenxid) DESC
LIMIT 10;

-- The danger zone: oldest xmin visible to any transaction
SELECT pg_current_xact_id() - backend_xmin AS xid_age_diff, pid, query
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
ORDER BY xid_age_diff DESC
LIMIT 5;
```

**Fix:** Kill the long-running transaction. Then run:

```sql
VACUUM ANALYZE orders;
-- or, to reclaim OS disk space (requires exclusive lock):
VACUUM FULL orders;
```

Prevention: set `idle_in_transaction_session_timeout`:

```sql
SET idle_in_transaction_session_timeout = '10min';
-- Or in postgresql.conf
idle_in_transaction_session_timeout = '600000'  -- 10 minutes in ms
```

This aborts any transaction that has been idle (waiting, not actively running) inside a `BEGIN` block for more than 10 minutes — the most common cause of bloat in web applications is a connection pool that leaves a transaction open between HTTP requests.

---

## Optimistic Concurrency Control (OCC)

Locking is **pessimistic**: assume conflicts will happen, prevent them with locks. Optimistic concurrency control takes the opposite view: *assume conflicts are rare; detect them at commit time*.

### OCC Protocol

Three phases:

```
1. READ PHASE
   Execute the transaction, recording:
   - Read set: {row versions read and their timestamps}
   - Write set: {modifications to be applied}
   No locks acquired during reads.

2. VALIDATION PHASE (at commit time)
   For each row in the read set:
     Has it been modified by any committed transaction since this transaction started?
     If yes: CONFLICT → abort and retry.
     If no: proceed.

3. WRITE PHASE
   If validation passes, apply write set atomically.
```

OCC is ideal when:
- Conflicts are rare (low contention workloads)
- Transactions are short (small read sets → fast validation)
- Read throughput is paramount (no lock overhead on reads)

OCC performs poorly under high contention because the abort rate rises — each aborted transaction wasted all its read/write work.

### OCC in Practice: Optimistic Locking with Version Numbers

Application-level OCC using a version column:

```sql
-- Schema
CREATE TABLE products (
    id INT PRIMARY KEY,
    name TEXT,
    stock INT,
    version INT DEFAULT 0
);

-- Optimistic update: only succeeds if version matches
UPDATE products
SET stock = $new_stock, version = version + 1
WHERE id = $id AND version = $expected_version;

-- Check rows_affected == 1. If 0, conflict: another update won between our read and write.
```

This pattern avoids explicit locking and is well-suited to web applications where:
- You read a row in one HTTP request
- The user makes a decision (takes seconds to minutes)
- You write in a second HTTP request

Without optimistic locking, you would need to hold a database lock for the entire user think time. With it, you only lock for the microseconds of the UPDATE statement.

---

## Serializable Snapshot Isolation (SSI)

SSI (covered briefly in Module 03) is worth understanding at the implementation level. Postgres uses it as its `SERIALIZABLE` implementation. It is the most sophisticated concurrency control mechanism in widespread use.

### Anti-Dependencies and Dangerous Cycles

SSI tracks **anti-dependencies** (also called rw-dependencies or rw-conflicts):
- T1 reads version V of row R at time t1
- T2 writes a new version of row R at time t2 > t1
- This is an anti-dependency T1 →rw T2 ("T1's read conflicts with T2's write")

A dangerous cycle is a set of transactions where every consecutive pair in the cycle has an anti-dependency:

```
T1 →rw T2 →rw T1   ← simplest dangerous cycle (two transactions)
```

When Postgres SSI detects such a cycle with all transactions still in-flight, it aborts one (the "pivot") with `ERROR 40001`. This prevents any non-serializable history.

### SIREAD Locks

SSI uses **SIREAD (Serializable-Read) locks** — lightweight markers recording "T1 read predicate P." These are not blocking locks (they do not prevent other transactions from writing). They are purely for tracking anti-dependencies.

```
SIREAD lock: (transaction_id, predicate)
  predicate can be: row lock ("row with ctid (7,3)"),
                    page lock ("all rows on page 7"),
                    relation lock ("all rows in table orders")
```

Lock granularity escalates automatically from row → page → relation as the number of SIREAD locks grows, to bound memory usage.

### Cost Model

SSI overhead vs Read Committed in production benchmarks:
- 10–20% throughput reduction for typical OLTP
- Under high contention: 30–50% abort rate overhead (retry cost)
- Memory: SIREAD lock table uses ~50 bytes per tracked read; with `max_pred_locks_per_transaction` at its default (64), the overhead is bounded

For most OLTP applications, the correctness guarantee is worth the overhead. The alternative — manually identifying every write-skew-prone invariant and adding `SELECT ... FOR UPDATE` or `LOCK TABLE` — is error-prone and often adds more overhead than SSI.

---

## Debugging Concurrency Problems

### Symptom: Deadlock in Logs

```
ERROR:  deadlock detected
DETAIL: Process 12345 waits for ShareLock on transaction 67890;
        blocked by process 98765.
        Process 98765 waits for ShareLock on transaction 12345;
        blocked by process 12345.
HINT:   See server log for query details.
```

**Diagnosis:**

1. Enable `log_lock_waits = on` and set `deadlock_timeout = 1s` (the default). This logs every lock wait that exceeds 1 second.

2. In a running system, query `pg_locks` to see current lock contention:

```sql
SELECT
    blocked_locks.pid     AS blocked_pid,
    blocked_activity.usename  AS blocked_user,
    blocking_locks.pid    AS blocking_pid,
    blocking_activity.usename AS blocking_user,
    blocked_activity.query    AS blocked_statement,
    blocking_activity.query   AS current_statement_in_blocking_process
FROM  pg_catalog.pg_locks         blocked_locks
JOIN  pg_catalog.pg_stat_activity blocked_activity  ON blocked_activity.pid = blocked_locks.pid
JOIN  pg_catalog.pg_locks         blocking_locks
      ON  blocking_locks.locktype = blocked_locks.locktype
      AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
      AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
      AND blocking_locks.page    IS NOT DISTINCT FROM blocked_locks.page
      AND blocking_locks.tuple   IS NOT DISTINCT FROM blocked_locks.tuple
      AND blocking_locks.pid != blocked_locks.pid
JOIN  pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
WHERE NOT blocked_locks.granted;
```

3. Look for the access pattern causing the cycle. The most common cause: two code paths that update the same two rows in opposite order (e.g., transaction A locks row 1 then row 2; transaction B locks row 2 then row 1). Fix by enforcing a consistent lock acquisition order in application code.

### Symptom: Lock Contention Causing p99 Latency Spikes

Not a deadlock — one transaction holds a lock and others pile up waiting.

```sql
-- Which queries are waiting the longest?
SELECT pid, wait_event_type, wait_event, query, now() - query_start AS wait_time
FROM pg_stat_activity
WHERE wait_event_type = 'Lock'
ORDER BY wait_time DESC;

-- What lock is being waited on and who holds it?
SELECT relation::regclass, mode, granted, pid
FROM pg_locks
WHERE relation = 'my_table'::regclass
ORDER BY granted DESC;
```

Common causes:
- A `VACUUM FULL` or `ALTER TABLE` taking an `AccessExclusiveLock` — blocks all reads and writes
- A long `UPDATE` holding row-level X locks on a hot table
- An idle transaction holding locks (`idle in transaction` in `pg_stat_activity`)

**Fix for idle-in-transaction:**
```sql
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND now() - xact_start > interval '5 minutes';
```

Then set `idle_in_transaction_session_timeout` in `postgresql.conf` to prevent recurrence.

### Symptom: Table Grows Unboundedly Despite Deletes (Version Bloat)

**Diagnosis:**

```sql
-- Check dead tuple count per table
SELECT relname, n_live_tup, n_dead_tup,
       round(n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0) * 100, 1) AS dead_pct,
       last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 10;

-- Check if autovacuum is blocked by a long transaction
SELECT pid, now() - xact_start AS txn_age, state, query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
  AND now() - xact_start > interval '10 minutes'
ORDER BY txn_age DESC;
```

If `dead_pct` > 20% and `last_autovacuum` is old (more than a few minutes for a write-heavy table), autovacuum is not keeping up or is being blocked.

**Tuning autovacuum for high-write tables:**

```sql
-- Per-table autovacuum settings (override the global defaults)
ALTER TABLE orders SET (
    autovacuum_vacuum_scale_factor = 0.01,   -- trigger at 1% dead, not 20%
    autovacuum_vacuum_threshold = 100,        -- trigger after 100 dead tuples (not 50)
    autovacuum_analyze_scale_factor = 0.005  -- refresh stats more aggressively
);
```

For extremely high-write tables (millions of rows/minute), consider increasing `autovacuum_max_workers` globally to let multiple vacuum workers run in parallel.

### Symptom: Transaction ID Wraparound Warning

```
WARNING:  database "mydb" must be vacuumed within 1073741399 transactions
HINT:     To avoid a database shutdown, execute a database-wide VACUUM in "mydb".
```

This is serious. Postgres uses 32-bit transaction IDs (modular arithmetic). After ~2 billion transactions, the ID wraps. To prevent seeing "future" transactions as "past," Postgres will refuse new transactions if VACUUM has not frozen old rows.

**Fix immediately:**

```sql
-- Run on the database, not per-table (freezes old rows database-wide)
VACUUM FREEZE;

-- Or target the most urgent table:
VACUUM FREEZE my_large_table;
```

**Prevention:** Ensure autovacuum is running and `autovacuum_freeze_max_age` (default 200 million transactions) is never exceeded. Monitor with:

```sql
SELECT datname, age(datfrozenxid) AS xid_age
FROM pg_database
ORDER BY age(datfrozenxid) DESC;
-- Alarm if age > 1.5 billion (approaching the 2-billion hard limit)
```

---

## Putting It Together: 2PL vs MVCC vs OCC Comparison

```
                   2PL (Strict)      MVCC (Postgres)    OCC (app-level)
───────────────────────────────────────────────────────────────────────
Read blocks write?    YES              NO                 NO
Write blocks read?    YES              NO                 NO
Write blocks write?   YES              YES (X lock)       NO (detect at commit)
Deadlocks possible?   YES              YES (write-write)  NO (aborts, no waits)
Best for              Low-concurrency  Read-heavy OLTP    Low-contention, short-txn
                      write workloads  mixed workloads    web CRUD
Overhead              Lock table       Version storage    Retry cost on conflict
                                       + Vacuum
───────────────────────────────────────────────────────────────────────
```

MVCC makes Postgres excellent at mixed read/write OLTP — long reports can run alongside fast CRUD operations without blocking each other. The cost is vacuum maintenance and version bloat management. This is not optional: understanding MVCC is prerequisite to operating Postgres in production.

---

## Checkpoint

You are ready to proceed when you can, without notes:

1. State the two-phase locking rule precisely and explain why the shrinking phase cannot acquire new locks.
2. Draw a wait-for graph for a three-transaction deadlock and explain how the database detects it.
3. Name two application-level patterns that prevent deadlocks before they occur.
4. Explain what `xmin` and `xmax` contain on a Postgres heap tuple and how a reader uses them to determine visibility.
5. Walk through what happens when Postgres executes `UPDATE users SET name='Bob' WHERE id=1`: how many row versions exist, what their xmin/xmax values are during the transaction, and what happens to the old version after commit.
6. Explain why a long-running read transaction on a write-heavy Postgres table causes version bloat, and what happens to autovacuum during this time.
7. Describe OCC's three phases and state when it outperforms 2PL.
8. State what `SIREAD locks` are and why they do not block writes in SSI.
9. Write the SQL query that identifies the transaction currently blocking autovacuum on a Postgres instance.
10. What does transaction ID wraparound mean, and what is the emergency command to prevent a database shutdown from it?

➡ You have completed the four foundational modules of Database Engineering. The next challenges will ask you to apply these concepts in code — query planners, index tuning, and schema design under real-world constraints.
