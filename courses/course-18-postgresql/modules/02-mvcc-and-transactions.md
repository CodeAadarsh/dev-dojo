# MVCC & Transactions

> **Module 02 · Course 18** — Postgres never blocks a reader with a writer or a writer with a reader. That guarantee comes entirely from MVCC. Understanding it at the tuple level — not just the isolation-level API — is what separates engineers who write correct concurrent code from those who introduce silent data corruption under load.

Multi-Version Concurrency Control (MVCC) is Postgres's concurrency engine. The core idea: instead of locking a row when you modify it, Postgres writes a *new version* of the row alongside the old one and uses transaction IDs to determine which version each concurrent transaction should see. Reads never block writes; writes never block reads. This module explains exactly how that works, from the 8-byte header fields on every tuple to the full machinery of Serializable Snapshot Isolation.

---

## Row Versioning: xmin, xmax, and ctid

Every row (tuple) in every heap page carries three hidden system columns that are the foundation of MVCC:

| Column  | Type  | Meaning |
|---------|-------|---------|
| `xmin`  | xid   | The transaction ID (XID) that **created** this row version |
| `xmax`  | xid   | The XID that **deleted or superseded** this row version; 0 = still live |
| `ctid`  | tid   | Physical location: `(block_number, item_index_within_block)` |

You can query these directly on any table:

```sql
SELECT xmin, xmax, ctid, id, amount
FROM orders
LIMIT 5;

-- typical output:
--  xmin  | xmax |  ctid  | id | amount
-- -------+------+--------+----+--------
--   1042 |    0 | (0,1)  |  1 | 100.00
--   1042 |    0 | (0,2)  |  2 | 250.00
--   1043 | 1055 | (0,3)  |  3 |  75.00   ← superseded by txn 1055
--   1055 |    0 | (1,1)  |  3 | 80.00    ← new version created by txn 1055
```

### What happens on UPDATE

An UPDATE in Postgres is **not** an in-place modification. It is logically a DELETE of the old version plus an INSERT of a new one:

```
BEFORE UPDATE:
  heap page 0:
  ┌────────────────────────────────────────────────────────────────┐
  │ (0,3) xmin=1043 xmax=0    amount=75.00   ← live tuple          │
  └────────────────────────────────────────────────────────────────┘

BEGIN;  -- transaction gets XID 1055
UPDATE orders SET amount = 80.00 WHERE id = 3;
COMMIT;

AFTER UPDATE:
  heap page 0:
  ┌────────────────────────────────────────────────────────────────┐
  │ (0,3) xmin=1043 xmax=1055  amount=75.00  ← dead (xmax set)    │
  └────────────────────────────────────────────────────────────────┘
  heap page 1 (or new slot in page 0):
  ┌────────────────────────────────────────────────────────────────┐
  │ (1,1) xmin=1055 xmax=0     amount=80.00  ← new live version   │
  └────────────────────────────────────────────────────────────────┘
```

The old tuple at `(0,3)` is now "dead" — its xmax points to the committed transaction that replaced it. A concurrent reader that holds a snapshot from before XID 1055 committed still sees the old version at `(0,3)`. A reader with a snapshot after 1055 committed sees the new version at `(1,1)`. Two versions of the "same" logical row coexist in the heap; visibility is decided at read time.

### Observing xmin/xmax change during a transaction

```sql
-- Session A
BEGIN;  -- gets XID, say 2001
INSERT INTO orders (id, amount) VALUES (99, 500);
-- xmin = 2001, xmax = 0, but it's NOT YET visible to other sessions
SELECT xmin, xmax, ctid FROM orders WHERE id = 99;
--  xmin  | xmax |  ctid
-- -------+------+--------
--   2001 |    0 | (5,4)

-- Session B (while Session A is still open)
SELECT xmin, xmax FROM orders WHERE id = 99;
-- (no rows) — Session B's snapshot predates XID 2001 being committed

-- back in Session A:
COMMIT;

-- Session B (after commit):
SELECT xmin, xmax FROM orders WHERE id = 99;
--  xmin  | xmax
-- -------+------
--   2001 |    0  ← now visible
```

### Why ctid changes on UPDATE

The `ctid` of the new tuple version is different from the old one because the new version is written to a new physical location. This is important for indexes: a B-tree index entry stores the ctid of the heap tuple it points to. When a row is updated, the index entry must eventually be updated to point to the new ctid — this is the core problem that HOT updates solve (Module 03).

---

## Snapshots and Tuple Visibility

A **snapshot** is a consistent point-in-time view of the database's transaction state. Every transaction (and in some isolation levels, every statement) acquires a snapshot, and the snapshot determines which row versions are visible.

A snapshot captures:
```
snapshot = {
  xmin:  the oldest XID still in progress when the snapshot was taken
         (all XIDs below xmin are either committed or aborted — stable)
  xmax:  the next XID to be assigned at snapshot time
         (all XIDs >= xmax didn't exist yet — invisible)
  xip[]: the list of XIDs that were actively in progress at snapshot time
         (these may commit after the snapshot — still invisible)
}
```

### The visibility rule

A tuple with `(t_xmin, t_xmax)` is **visible** to a snapshot if and only if:

1. `t_xmin` is committed AND `t_xmin` < snapshot.xmax AND `t_xmin` NOT IN snapshot.xip
   → the creating transaction finished before the snapshot and is not still in progress
2. AND either:
   - `t_xmax = 0` (not deleted)
   - OR `t_xmax` is NOT committed (the deleting transaction rolled back)
   - OR `t_xmax` >= snapshot.xmax (deleted by a transaction that started after the snapshot)
   - OR `t_xmax` IN snapshot.xip (deleting transaction was in progress at snapshot time)

This rule is evaluated per-tuple during every scan. It's implemented in `HeapTupleSatisfiesMVCC()` in the Postgres source. No locks are acquired to check visibility.

### Snapshot acquisition timing

The timing of snapshot acquisition varies by isolation level:

- **READ COMMITTED**: a fresh snapshot is acquired at the start of **each SQL statement**. Two SELECTs in the same READ COMMITTED transaction can see different data if committed changes arrive between them.
- **REPEATABLE READ / SERIALIZABLE**: the snapshot is acquired once at the start of the **first SQL statement** in the transaction and held for the entire transaction duration.

---

## The Commit Log (pg_xact / CLOG)

How does the visibility check know whether XID 1055 is committed or not? Postgres maintains the **commit log** (historically called CLOG, stored in `$PGDATA/pg_xact/`). It's a bitmapped file storing 2 bits per XID:

| Bits | Meaning |
|------|---------|
| `00` | IN_PROGRESS |
| `01` | COMMITTED |
| `10` | ABORTED |
| `11` | SUB_COMMITTED (used for savepoints) |

Checking visibility requires reading the CLOG for both `t_xmin` and `t_xmax`. To avoid reading the CLOG on every tuple access, Postgres caches the result in the tuple's `t_infomask` field as **hint bits**:

- `HEAP_XMIN_COMMITTED` — t_xmin is known committed
- `HEAP_XMIN_INVALID` — t_xmin is known aborted/rolled back
- `HEAP_XMAX_COMMITTED` — t_xmax is known committed
- `HEAP_XMAX_INVALID` — t_xmax is absent or known rolled back

The first transaction to access a tuple with uncommitted-status xmin or xmax writes the hint bit into the page. This is a "dirty" write that doesn't go through the WAL on older PG versions (which created complications with `full_page_writes` — see Module 04). From PG 10+ these hint-bit updates are WAL-logged as FPIs when necessary.

**Implication for restores:** A table freshly loaded from `pg_dump` has no hint bits set. The first sequential scan rewrites hint bits for every tuple — measurably higher I/O and more WAL generation than steady-state. Running `VACUUM ANALYZE` right after a restore pre-sets hint bits and updates the visibility map.

---

## The Four Isolation Levels

SQL defines four isolation levels to protect against four classes of concurrency anomalies. Postgres implements all four, and is stricter than the SQL standard in some cases.

### The anomalies

**Dirty read** — Transaction A reads data written by transaction B before B commits. If B rolls back, A has read data that never existed. Postgres prevents dirty reads at all isolation levels (the floor is always READ COMMITTED).

**Non-repeatable read** — Transaction A reads row R, then B commits an update to R, then A reads R again and gets a different value within the same transaction.

**Phantom read** — Transaction A queries a range of rows (e.g. `WHERE amount > 100`), then B inserts a new row that would match, then A re-queries and sees the new row.

**Write skew** — Two transactions each read a set of rows and each write a row based on what they read. Their reads don't overlap their writes, so neither locks the other out, but the combined effect violates an application-level invariant. Only preventable with SERIALIZABLE.

### Isolation levels and what Postgres guarantees

| Level               | Dirty Read | Non-Repeatable | Phantom | Write Skew |
|---------------------|-----------|----------------|---------|------------|
| READ UNCOMMITTED    | prevented* | yes            | yes     | yes        |
| READ COMMITTED      | prevented  | yes            | yes     | yes        |
| REPEATABLE READ     | prevented  | prevented      | prevented† | yes    |
| SERIALIZABLE        | prevented  | prevented      | prevented | prevented |

*Postgres never allows dirty reads regardless of the specified level.
†Postgres REPEATABLE READ prevents phantom reads — stronger than the SQL standard requires.

### READ COMMITTED in depth

This is the default. Every statement gets a fresh snapshot. This enables a subtle but common bug:

```sql
-- Session A
BEGIN;
-- reads balance: 1000
SELECT balance FROM accounts WHERE id = 42;

-- Session B concurrently:
BEGIN;
UPDATE accounts SET balance = balance - 500 WHERE id = 42;
COMMIT;

-- Session A, same transaction, second read:
SELECT balance FROM accounts WHERE id = 42;
-- returns 500 — the snapshot was refreshed for this new statement
-- this IS a non-repeatable read; READ COMMITTED explicitly allows it
COMMIT;
```

This behaviour is correct by design but surprises engineers who expect their two SELECTs in the same transaction to agree. It also affects UPDATE statements: the WHERE clause is re-evaluated on the latest snapshot, which means an UPDATE can modify rows that didn't exist when the transaction started — another legitimate but sometimes surprising behaviour.

### REPEATABLE READ in depth

The snapshot is frozen at the start of the transaction. Re-reads of the same rows return the same data. However, if you attempt to UPDATE or DELETE a row that was modified by a concurrent committed transaction, Postgres raises:

```
ERROR:  could not serialize access due to concurrent update
SQLSTATE: 40001
```

This is correct — you were about to write based on data you read under a stale snapshot. The rule is: **application code using REPEATABLE READ must catch 40001 and retry the entire transaction from the beginning**.

```sql
-- Set isolation level for a single transaction:
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT balance FROM accounts WHERE id = 42;   -- snapshot frozen here
-- concurrent commit happens...
UPDATE accounts SET balance = balance - 100 WHERE id = 42;
-- ERROR: could not serialize access due to concurrent update (if someone else updated this row)
ROLLBACK;
-- retry entire transaction
```

### SERIALIZABLE and SSI

Postgres 9.1 introduced Serializable Snapshot Isolation (SSI), a landmark algorithm that detects write-skew without locks. It is the only isolation level that guarantees true serial execution — as if all transactions ran one at a time in some order.

SSI works by tracking **predicate locks** (also called SIRead locks) that capture what each transaction has read. When the system detects a **rw-anti-dependency cycle** between concurrent transactions, it aborts one of them.

#### Write skew example: on-call scheduling

```sql
-- Setup: doctors_on_call table, at least one must always be on call
CREATE TABLE doctors_on_call (doctor text PRIMARY KEY, on_call bool);
INSERT INTO doctors_on_call VALUES ('Alice', true), ('Bob', true);

-- Session A (SERIALIZABLE):
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) FROM doctors_on_call WHERE on_call = true;  -- returns 2
-- "there are 2, so I can safely take Alice off"
UPDATE doctors_on_call SET on_call = false WHERE doctor = 'Alice';

-- Session B (SERIALIZABLE) runs concurrently:
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) FROM doctors_on_call WHERE on_call = true;  -- also returns 2
-- "there are 2, so I can safely take Bob off"
UPDATE doctors_on_call SET on_call = false WHERE doctor = 'Bob';
COMMIT;

-- Session A:
COMMIT;
-- ERROR: could not serialize access due to read/write dependencies among transactions
-- DETAIL:  Reason code: Canceled on identification as a pivot, during commit attempt.
-- HINT:  The transaction might succeed if retried.
```

SSI detected that A read rows that B wrote, and B read rows that A wrote — a cycle that means their combined execution cannot be equivalent to any serial ordering.

#### SSI internals: rw-anti-dependency detection

SSI tracks three types of dependencies between concurrent transactions:
- **wr-dependency**: T1 writes something that T2 reads (snapshot handles this)
- **ww-dependency**: T1 and T2 both write the same row
- **rw-anti-dependency**: T1 reads something that T2 later writes (this is the new one SSI tracks)

A cycle involving two rw-anti-dependency edges is called a **dangerous structure**. SSI maintains a list of "siread locks" per predicate (rows or page ranges read) and checks for cycles at commit time.

#### Cost of SSI

SSI uses more memory (predicate locks in `pg_locks`) and more CPU for cycle detection. The overhead is typically < 5% for normal OLTP and < 20% for write-heavy workloads. The key parameter:

```sql
SHOW max_pred_locks_per_transaction;  -- default 64
-- if this is exhausted, Postgres escalates to page-level or relation-level SIRead locks
-- which is conservative (more aborts) but not incorrect
```

If your workload has many serializable transactions and you see many aborts, consider:
1. Making transactions shorter (reduces overlap window)
2. Increasing `max_pred_locks_per_transaction`
3. Batching work to reduce concurrency

---

## Deadlocks

A deadlock is a cycle in the wait-for graph: transaction A holds a lock that B needs, and B holds a lock that A needs.

```
  Txn A: holds RowExclusive on row_1, waiting for RowExclusive on row_2
  Txn B: holds RowExclusive on row_2, waiting for RowExclusive on row_1
         ↗ cycle → deadlock
```

Postgres detects deadlocks with a background scan that runs every `deadlock_timeout` (default 1 second). When a cycle is found, Postgres picks one transaction to abort (typically the one that has done less work or the one that is cheaper to abort) and returns:

```
ERROR:  deadlock detected
DETAIL:  Process 1301 waits for ShareLock on transaction 5678; blocked by process 5678.
         Process 5678 waits for ShareLock on transaction 1301; blocked by process 1301.
HINT:   See server log for query details.
SQLSTATE: 40P01
```

The surviving transaction proceeds normally. The aborted transaction must be retried by the application.

### Avoiding deadlocks with consistent lock ordering

Deadlocks are entirely avoidable if all code acquires multiple locks in the same canonical order. The most common pattern: sort the rows by ID and always lock the lower ID first.

```sql
-- DEADLOCK-PRONE: order depends on which account is "from" vs "to"
BEGIN;
UPDATE accounts SET balance = balance - 100 WHERE id = :from_id;  -- may lock 42 first or 99 first
UPDATE accounts SET balance = balance + 100 WHERE id = :to_id;
COMMIT;

-- DEADLOCK-SAFE: always lock the lower ID first
BEGIN;
-- acquire both locks in sorted order
WITH lock_order AS (
  SELECT id FROM accounts WHERE id IN (:from_id, :to_id) ORDER BY id FOR UPDATE
)
UPDATE accounts
SET balance = balance + (CASE WHEN id = :to_id THEN 100 ELSE -100 END)
WHERE id IN (:from_id, :to_id);
COMMIT;
```

Or enforce it at the application layer: always pass `min(from_id, to_id)` as the first UPDATE and `max(from_id, to_id)` as the second.

---

## SELECT FOR UPDATE, FOR SHARE, SKIP LOCKED

MVCC means readers don't block writers, but it does NOT mean you can safely do read-modify-write without coordination. If two sessions both read `balance = 100` and both subtract 50, they both commit `balance = 50` — one decrement is lost. This is the **lost update** problem.

### FOR UPDATE

```sql
BEGIN;
-- Takes an exclusive lock on the selected rows; no other transaction can
-- UPDATE, DELETE, or FOR UPDATE these rows until we commit or rollback.
SELECT balance FROM accounts WHERE id = 42 FOR UPDATE;
-- safe to modify: nobody else can touch this row
UPDATE accounts SET balance = balance - 50 WHERE id = 42;
COMMIT;
```

`FOR UPDATE` causes the SELECT to write a lock entry in the lock table and sets `xmax` on the tuple to a "not committed yet" value. Concurrent transactions that try to SELECT ... FOR UPDATE on the same row will wait until the first transaction commits or rolls back.

### FOR SHARE

```sql
-- Multiple transactions can hold FOR SHARE simultaneously (shared lock).
-- A FOR UPDATE will wait for all FOR SHARE holders to release.
SELECT config_value FROM configs WHERE key = 'rate_limit' FOR SHARE;
-- safe to read without anyone changing it mid-transaction
```

Use FOR SHARE when you need to read a row that must not change while you're acting on it, but you don't need to write it yourself.

### SKIP LOCKED — the work queue pattern

```sql
-- Reliable, concurrent work queue dequeue — the canonical Postgres pattern:
BEGIN;
SELECT id, payload
FROM jobs
WHERE status = 'pending'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;
-- If another worker has this row locked, SKIP LOCKED returns no rows from that row
-- (moves on to the next unlocked row), instead of blocking.

-- Process the job...
UPDATE jobs SET status = 'processing' WHERE id = :job_id;
COMMIT;
```

`SKIP LOCKED` makes this non-blocking: if a row is locked by another worker, this query simply skips it and picks the next available row. Multiple workers can drain the same table concurrently without deadlocks or blocking each other.

### NOWAIT

```sql
-- Fail immediately if the row is locked, rather than waiting:
SELECT * FROM orders WHERE id = 42 FOR UPDATE NOWAIT;
-- ERROR:  could not obtain lock on row in relation "orders"
-- Useful when you want to "try-and-fail-fast" rather than queue up behind a lock.
```

---

## Debugging: MVCC & Transactions

### Lost updates (the silent data corruption)

The lost update problem does not produce any error. Both transactions succeed, but one write silently overwrites the other. It happens at READ COMMITTED when you do read-modify-write without a locking read.

```sql
-- Simulate:
-- Session A and B both execute this "simultaneously":
BEGIN;
SELECT quantity FROM inventory WHERE item_id = 7;  -- both see 10
-- application computes 10 - 1 = 9
UPDATE inventory SET quantity = 9 WHERE item_id = 7;
COMMIT;
-- Both commit "9". The real answer should be 8 (two decrements).
```

Detection: monitor the `n_tup_upd` counter and cross-reference with expected write volume. More robustly, use an **optimistic lock**:

```sql
-- Optimistic locking: include current value in WHERE
UPDATE inventory
SET quantity = :new_qty
WHERE item_id = 7 AND quantity = :expected_qty;
-- check affected_rows; if 0, someone changed it between your read and write → retry
```

Or use `FOR UPDATE` to make it pessimistic and guaranteed-correct.

### Serialization failures (SQLSTATE 40001 / 40P01)

Any code using REPEATABLE READ or SERIALIZABLE must handle these errors. The pattern:

```python
import psycopg2
from psycopg2 import errors

def transfer_funds(conn, from_id, to_id, amount, max_retries=5):
    for attempt in range(max_retries):
        try:
            with conn.cursor() as cur:
                cur.execute("BEGIN ISOLATION LEVEL SERIALIZABLE")
                cur.execute("SELECT balance FROM accounts WHERE id = %s FOR UPDATE", (from_id,))
                # ... business logic ...
                cur.execute("COMMIT")
                return
        except (errors.SerializationFailure, errors.DeadlockDetected):
            conn.rollback()
            if attempt == max_retries - 1:
                raise
            time.sleep(0.05 * (2 ** attempt))  # exponential backoff
```

The retry loop must restart the **entire transaction** — you cannot retry just the failed statement. The snapshot must be taken fresh.

Monitor failure rates:
```sql
SELECT datname,
       conflicts       AS "serialization conflicts",
       deadlocks,
       blk_read_time,
       blk_write_time
FROM pg_stat_database
WHERE datname = current_database();
```

### Long-running transactions causing MVCC bloat

The most operationally dangerous MVCC scenario: a long-running transaction holds its snapshot open. Autovacuum cannot reclaim dead tuples that are visible to that snapshot. Tables with high update/delete rates accumulate dead tuples without relief, causing unbounded table growth.

```sql
-- Find the oldest open transaction (biggest bloat risk)
SELECT pid,
       usename,
       application_name,
       now() - xact_start                        AS txn_age,
       now() - query_start                       AS query_age,
       state,
       left(query, 80)                           AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start ASC
LIMIT 10;
```

Replication standbys also hold snapshot horizons via their replication slots:

```sql
-- Replication slots holding back VACUUM
SELECT slot_name,
       slot_type,
       active,
       xmin,                                                   -- oldest XID the slot needs
       catalog_xmin,
       pg_size_pretty(
         pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
       )                                                       AS retained_wal
FROM pg_replication_slots
ORDER BY restart_lsn ASC;
```

An idle or disconnected replication slot with an old `xmin` will block VACUUM indefinitely. If the slot is no longer needed:
```sql
SELECT pg_drop_replication_slot('slot_name');
```

Estimating table bloat without extensions:
```sql
SELECT
  relname,
  n_live_tup,
  n_dead_tup,
  round(n_dead_tup::numeric / nullif(n_live_tup + n_dead_tup, 0) * 100, 1) AS dead_pct,
  last_autovacuum,
  last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC;
```

Manually trigger VACUUM if autovacuum isn't running:
```sql
-- Non-locking, safe during production:
VACUUM VERBOSE orders;

-- Full rewrite (exclusive lock, reclaims disk space below the high-water mark):
-- Only in maintenance windows:
VACUUM FULL orders;
ANALYZE orders;
```

### Diagnosing lock contention

```sql
-- Full lock table with relation names and blocking chains
SELECT
  l.pid,
  l.locktype,
  l.relation::regclass     AS relation,
  l.mode,
  l.granted,
  a.query,
  pg_blocking_pids(l.pid)  AS blocked_by
FROM pg_locks l
JOIN pg_stat_activity a USING (pid)
WHERE NOT l.granted
ORDER BY l.pid;
```

The `lock_timeout` setting makes a query fail rather than wait indefinitely — a good defensive default for application connections:

```sql
SET lock_timeout = '5s';
-- or in postgresql.conf:
-- lock_timeout = '5s'
```

---

## Checkpoint

Make sure you can reason about these before moving forward:

1. What are `xmin`, `xmax`, and `ctid`? What values do they hold immediately after an UPDATE on a row, for both the old and new version?
2. Define a snapshot. What are its three fields, and what does each bound?
3. Explain the non-repeatable read anomaly and state which isolation level prevents it.
4. Describe the write-skew anomaly. Why does REPEATABLE READ not prevent it?
5. How does SSI detect a dangerous structure without locking reads? What is an rw-anti-dependency?
6. What is a deadlock at the OS/kernel level? Name the canonical prevention technique.
7. `SELECT FOR UPDATE SKIP LOCKED` — describe exactly what it does and why it is the correct pattern for a work queue.
8. You receive SQLSTATE 40001 in a SERIALIZABLE transaction. What must your application code do? Why is retrying only the failed statement wrong?
9. A table with 10M rows has `n_dead_tup = 3,000,000` and `last_autovacuum = NULL`. Name three distinct reasons autovacuum might not have run.
10. An idle replication slot has `xmin = 12345` and your current XID is 9,000,000. What is the consequence for VACUUM, and how do you fix it?

➡ Next: **Storage: Pages, TOAST & HOT** — how Postgres physically stores rows and why update patterns have dramatic effects on storage efficiency.
