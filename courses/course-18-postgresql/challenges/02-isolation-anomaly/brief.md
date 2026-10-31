# Isolation Anomaly — Prevent the Lost Update

> **Prereq:** Docker must be running. The challenge uses a local `dojo-pg` container on port 55432.

A customer refund system processes two concurrent "goodwill credit" requests for the same account. Each request is supposed to add $500.00 to the account balance. After both complete, the support team checks the balance: it went up by only $500, not $1000. One credit disappeared silently. No error was logged. No exception was raised. The balance is just wrong.

This is a **lost update** — one of the most dangerous concurrency bugs in financial systems because it produces no error and leaves the database in a state that *looks* consistent.

## Context

`setup.sh` creates a `dojo-pg` container (Postgres 16) and seeds an `accounts` table:

```
~/.kube-dojo-work/02-isolation-anomaly/
├── broken.sql    # demonstrates the lost update — observe this first
└── fix.sql       # EDIT THIS to prevent the lost update
```

**Docker prereq:** Docker must be running before you execute setup.sh.

```bash
bash courses/course-18-postgresql/challenges/02-isolation-anomaly/setup.sh
```

## Understanding the Lost Update

The bug lives in a **read-modify-write** pattern — a three-step operation that is NOT atomic by default:

```
Step 1: SELECT balance FROM accounts WHERE id = 1;   -- read: 1000
Step 2: compute new_balance = 1000 + 500 = 1500
Step 3: UPDATE accounts SET balance = 1500 WHERE id = 1;
```

When two transactions execute these steps concurrently with default `READ COMMITTED` isolation:

```
Time  Transaction A (agent 1)          Transaction B (agent 2)
────  ───────────────────────────────  ───────────────────────────────
T1    BEGIN
T2    SELECT balance → 1000            BEGIN
T3                                     SELECT balance → 1000   ← stale!
T4    [business logic, 0.3 s]          [business logic, 0.3 s]
T5    UPDATE balance = 1000+500=1500
T6    COMMIT
T7                                     UPDATE balance = 1000+500=1500
T8                                     COMMIT                  ← OVERWRITES A!
```

Both transactions read `1000` (before either committed). Both compute `1500`. A commits, balance becomes 1500. B then commits, balance becomes 1500 again — A's update is **lost**. The correct answer is 2000.

The problem is not the isolation level per se. Under `READ COMMITTED`, each statement sees the most recently committed data. But the three-step pattern reads the value at T2/T3, sleeps during business logic, and writes at T5/T7 — B's write at T7 uses the value it read at T3 (before A's commit at T6), so it blindly overwrites A's result.

## The Fix — SELECT FOR UPDATE

The solution is to hold a **row-level exclusive lock** from the moment you read the row until you commit:

```sql
SELECT balance INTO v_bal FROM accounts WHERE id = 1 FOR UPDATE;
```

`FOR UPDATE` tells PostgreSQL: *"I intend to update this row. Lock it now."* Any other transaction issuing a `FOR UPDATE` (or a plain `UPDATE`) on the same row will block until the first transaction commits or rolls back.

With the fix applied:

```
Time  Transaction A                    Transaction B
────  ───────────────────────────────  ───────────────────────────────
T1    BEGIN
T2    SELECT ... FOR UPDATE → 1000     BEGIN
T3    [row locked by A]                SELECT ... FOR UPDATE → BLOCKS
T4    [business logic]
T5    UPDATE balance = 1500
T6    COMMIT   (lock released)
T7                                     SELECT ... FOR UPDATE → 1500  ← correct!
T8                                     [business logic]
T9                                     UPDATE balance = 2000
T10                                    COMMIT
```

B blocks at T3, waits for A to commit, then reads the **updated** value 1500 and computes 2000. Both credits are preserved.

## Your Task

Edit `~/.kube-dojo-work/02-isolation-anomaly/fix.sql`. Find the SELECT line inside the DO block and add `FOR UPDATE` at the end of it. The verify script will run `fix.sql` twice concurrently and assert the final balance equals 1000 (starting from 0, adding 500 twice).

**Exact conditions `verify.sh` checks:**

1. `accounts` table exists.
2. `fix.sql` exists in the work directory.
3. After resetting `balance = 0`, running `fix.sql` twice concurrently, the final balance is exactly `1000`.

## Verify

```bash
bash courses/course-18-postgresql/challenges/02-isolation-anomaly/verify.sh
```

## Why This Matters

Lost updates are the #1 silent data corruption pattern in OLTP databases. They surface in:

- **E-commerce**: two sessions both read remaining stock = 1, both sell it, oversell.
- **Finance**: concurrent refunds or credits overwrite each other.
- **Seat reservation**: two users both read "available", both book the last seat.

The pattern always looks like: read → compute → write, with no lock held across all three steps. The fix is always one of:
- `SELECT ... FOR UPDATE` (simplest — holds a row lock)
- Atomic `UPDATE accounts SET balance = balance + 500` (avoids the separate read; the `+` runs inside the locked UPDATE)
- `SERIALIZABLE` isolation with retry on `ERROR 40001` (serialization failure)

At the SDE-2 level you are expected to spot this pattern in code review without having to reproduce the race condition.
