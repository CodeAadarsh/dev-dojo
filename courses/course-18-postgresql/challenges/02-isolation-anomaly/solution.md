# Solution — Isolation Anomaly: Prevent the Lost Update

## The Answer

Open `~/.kube-dojo-work/02-isolation-anomaly/fix.sql` and change the SELECT line:

```sql
-- Before (broken)
SELECT balance INTO v_bal FROM accounts WHERE id = 1;

-- After (fixed)
SELECT balance INTO v_bal FROM accounts WHERE id = 1 FOR UPDATE;
```

That single clause addition is the entire fix. The full corrected `fix.sql`:

```sql
BEGIN;
DO $$
DECLARE
    v_bal NUMERIC;
BEGIN
    SELECT balance INTO v_bal FROM accounts WHERE id = 1 FOR UPDATE;
    PERFORM pg_sleep(0.2);
    UPDATE accounts SET balance = v_bal + 500 WHERE id = 1;
END;
$$;
COMMIT;
```

Apply and verify:

```bash
# Apply fix.sql once to confirm it runs without errors
docker exec -i dojo-pg psql -U postgres -d dojo < \
  ~/.kube-dojo-work/02-isolation-anomaly/fix.sql

# Run the verifier — it resets balance to 0 and runs fix.sql twice concurrently
bash courses/course-18-postgresql/challenges/02-isolation-anomaly/verify.sh
```

---

## What FOR UPDATE Actually Does

`SELECT ... FOR UPDATE` is a **locking read**. It acquires an exclusive row-level lock on every row returned by the SELECT, in the same way a subsequent `UPDATE` on those rows would. The lock is held until the transaction commits or rolls back.

Mechanically, PostgreSQL implements this by setting the `xmax` field of the row's tuple header to the current transaction ID and marking it as a "key share" or "update" lock. Any concurrent transaction that tries to acquire a conflicting lock on the same row will block in the lock manager until the holder commits.

```
Transaction A: FOR UPDATE on row id=1
  → sets row's xmax = TxID(A), lock_mode = ExclusiveLock
  → row is now "locked"

Transaction B: FOR UPDATE on row id=1
  → detects xmax = TxID(A) is still active
  → enters pg_locks wait queue
  → blocks until A commits or rolls back
  → after A commits: B reads the committed tuple (balance=500)
  → B proceeds with v_bal=500, writes 1000
```

This serializes the two transactions without either one failing — they simply run one after the other, each seeing the state the previous one left.

---

## Why the Default (READ COMMITTED) Is Not Enough Here

Under `READ COMMITTED` isolation (PostgreSQL's default), each individual statement sees the most recently committed data. A plain `SELECT` without `FOR UPDATE` sees a snapshot taken at statement start. This means:

- A reads balance at T=0: v_bal = 0 (no other committed writes yet)
- B reads balance at T=0.1s (before A commits): v_bal = 0 (same reason)
- A's UPDATE and COMMIT: balance = 500
- B's UPDATE with its stale v_bal=0: balance = 0 + 500 = 500 (WRONG)

`READ COMMITTED` guarantees you never see uncommitted data (no dirty reads). It does **not** guarantee you see data that was committed after your statement started. The gap between "statement start" and "when you apply the result to a write" is the window where the lost update lives.

---

## Alternative Fixes

### 1. Atomic UPDATE (avoid the explicit read entirely)

The simplest fix when the computation is straightforward is to fold the read and write into a single atomic statement:

```sql
BEGIN;
UPDATE accounts SET balance = balance + 500 WHERE id = 1;
COMMIT;
```

The `balance + 500` expression is evaluated by the UPDATE statement itself, which holds an exclusive row lock from the moment it locates the row. There is no separate SELECT, so there is no gap. This works for simple arithmetic. It does not work when the business logic between read and write is complex (e.g., read balance, call an external pricing API, compute a percentage, write back).

### 2. SERIALIZABLE Isolation

```sql
BEGIN ISOLATION LEVEL SERIALIZABLE;
DO $$
DECLARE
    v_bal NUMERIC;
BEGIN
    SELECT balance INTO v_bal FROM accounts WHERE id = 1;
    PERFORM pg_sleep(0.2);
    UPDATE accounts SET balance = v_bal + 500 WHERE id = 1;
END;
$$;
COMMIT;
```

PostgreSQL's SSI (Serializable Snapshot Isolation) tracks read-write dependencies between transactions. When it detects a cycle that would produce a non-serializable outcome, it aborts one transaction with:

```
ERROR:  could not serialize access due to concurrent update
DETAIL:  Process 12345 updated a tuple that process 12346 was also trying to update.
```

The aborted transaction must be **retried by the application**. SSI prevents the anomaly but introduces the complexity of retry logic. It also has a higher per-transaction overhead because the database must track the read-sets of active serializable transactions.

For this challenge, the verifier does not implement retry, so `SERIALIZABLE` without retry would leave balance=500 (only one transaction succeeds). Use `FOR UPDATE` for this challenge.

### 3. REPEATABLE READ

`REPEATABLE READ` in PostgreSQL is NOT equivalent to `FOR UPDATE`. Under `REPEATABLE READ`, when B's `UPDATE` attempts to modify a row that A has already committed to, PostgreSQL aborts B with:

```
ERROR:  could not serialize access due to concurrent update
```

This prevents the lost update from silently corrupting data, but B's operation still fails and requires retry. The balance would be 500 after only A succeeds (B failed). Without retry in the fix.sql, `REPEATABLE READ` fails the verify just like the broken case.

---

## How to Reproduce the Broken Scenario

Open two terminals and run `broken.sql` nearly simultaneously:

```bash
# Terminal 1
docker exec dojo-pg psql -U postgres -d dojo -c "UPDATE accounts SET balance = 1000 WHERE id=1;"
docker exec -i dojo-pg psql -U postgres -d dojo < \
  ~/.kube-dojo-work/02-isolation-anomaly/broken.sql

# Terminal 2 (run within a second of Terminal 1)
docker exec -i dojo-pg psql -U postgres -d dojo < \
  ~/.kube-dojo-work/02-isolation-anomaly/broken.sql
```

Wait for both to finish, then:

```bash
docker exec dojo-pg psql -U postgres -d dojo \
  -c "SELECT balance FROM accounts WHERE id=1;"
```

Expected: 2000. Actual: 1500. One `+500` was lost.

---

## Observing the Lock in Action

To see `FOR UPDATE` blocking in real time, open two psql sessions:

```bash
# Session A: hold the lock
docker exec -it dojo-pg psql -U postgres -d dojo
BEGIN;
SELECT balance FROM accounts WHERE id=1 FOR UPDATE;
-- don't commit yet
```

```bash
# Session B (separate terminal): try to lock the same row
docker exec -it dojo-pg psql -U postgres -d dojo
BEGIN;
SELECT balance FROM accounts WHERE id=1 FOR UPDATE;
-- hangs here, blocked by Session A
```

In a third terminal:

```bash
docker exec dojo-pg psql -U postgres -d dojo \
  -c "SELECT pid, wait_event_type, wait_event, query
      FROM pg_stat_activity
      WHERE wait_event = 'relation' OR wait_event_type = 'Lock';"
```

You will see Session B in a `Lock` wait. Go back to Session A and `COMMIT;` — Session B unblocks immediately.

This is the exact mechanism that prevents the lost update: B cannot proceed past its SELECT until A finishes.

---

## Production Checklist

When you see a read-modify-write pattern in a code review, ask:

1. **Is this in a transaction?** If not, even `FOR UPDATE` won't help (no transaction boundary to hold the lock to).
2. **Is the lock granular enough?** `FOR UPDATE` without `WHERE` locks all rows, which serializes everything. Add the primary key predicate.
3. **What is the contention rate?** At high concurrency, `FOR UPDATE` on a hot row creates a queue. Consider the atomic `UPDATE col = col + delta` pattern instead to avoid the lock altogether.
4. **Is retry handled?** If using `SERIALIZABLE`, the application must retry on `SQLSTATE 40001` (serialization failure). Most ORMs have a built-in retry hook.
