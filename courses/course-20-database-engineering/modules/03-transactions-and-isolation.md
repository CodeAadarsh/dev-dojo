# The Transaction Model: ACID & Isolation

> **Module 03 · Course 20** — "Transaction" is one of those words engineers use confidently until someone asks them to define it precisely. This module fixes that. ACID is not a vague aspiration — each letter has a precise, testable meaning. The isolation anomalies are not edge cases for database nerds — they are real bugs that will silently corrupt your data and only surface in production under load. After this module you will be able to look at any race condition, name the anomaly, and state which isolation level prevents it.

This is the module where database theory and production incidents finally connect. Every "phantom row" bug, every "balance went negative despite a check," every "I read my own write but my colleague didn't" is a specific isolation anomaly with a specific name and a specific cure.

---

## ACID, Precisely

ACID was named by Haerder and Reuter in 1983 and remains the foundation of relational database semantics. Each property is a guarantee the database makes to the application:

### Atomicity

**All-or-nothing execution.** A transaction is the smallest unit that can commit or abort. If any statement inside a transaction fails, the entire transaction is rolled back to the state it was in before the first statement — no partial effects are visible to other transactions or persist after a crash.

```sql
BEGIN;
UPDATE accounts SET balance = balance - 500 WHERE id = 1;
UPDATE accounts SET balance = balance + 500 WHERE id = 2;
COMMIT;
```

Either both updates commit, or neither does. The engine achieves this via the UNDO log (Module 02): on abort, it replays before-images in reverse order.

Atomicity says nothing about concurrency. A transaction can be atomic but still read garbage written by another concurrent transaction. That is isolation's job.

### Consistency

**User-defined invariants are maintained.** Consistency is actually a *user contract*, not a database mechanism. The database enforces CHECK constraints, NOT NULL, foreign keys, and UNIQUE constraints. The *application* is responsible for higher-level invariants (e.g., "no account can go below zero" — enforce with a CHECK constraint or application logic, not just by hoping for atomicity).

Consistency as a letter in ACID has historically been controversial: Brewer (the CAP theorem author) called it "a bit of a stretch" because the database cannot guarantee invariants the application does not express. In practice: define your constraints in the schema, and let the database enforce them atomically.

### Isolation

**Concurrent transactions see a consistent view of data.** Each transaction executes as if it were the only one running, even when hundreds of transactions are concurrent. The strength of this guarantee varies — this is the subject of the rest of this module.

### Durability

**Committed changes survive crashes.** Once the database returns "committed" to the client, the change will persist even if the system crashes immediately afterward. Durability is implemented by the WAL commit rule from Module 02: the COMMIT log record must be on stable storage before the commit acknowledgment is sent.

---

## Isolation Levels and Anomalies

The SQL standard defines four isolation levels. They are defined *by the anomalies they permit or prevent* — not by implementation mechanism.

```
ISO SQL isolation levels (weakest → strongest):
  Read Uncommitted
  Read Committed       ← most engines' default (Postgres, MySQL)
  Repeatable Read      ← MySQL InnoDB default (with MVCC)
  Serializable         ← strongest
```

An anomaly is an unexpected or incorrect result that arises from concurrent execution. There are six classical anomalies worth knowing precisely:

| Anomaly | Short description |
|---------|------------------|
| Dirty Read | Read another transaction's uncommitted write |
| Non-Repeatable Read | Read the same row twice, get different values |
| Phantom Read | Re-execute a range query, get different rows |
| Write Skew | Two transactions each read a set, then both write based on stale reads |
| Lost Update | Two concurrent increments result in only one increment persisted |
| Dirty Write | Overwrite another transaction's uncommitted write |

### Anomaly 1: Dirty Read

**What happens:** Transaction A reads a value that Transaction B has written but not yet committed. If B then rolls back, A has acted on data that never existed.

```
Timeline:
  T1                        T2
  BEGIN
  UPDATE balance = 900      ← not yet committed
  (still in transaction)
                            BEGIN
                            SELECT balance → reads 900  ← DIRTY READ
                            ... uses 900 to make a decision
  ROLLBACK                  ← T1 undone, balance is still 1000
                            ... T2 made a wrong decision based on phantom data
```

**Prevented by:** Read Committed and above.

### Anomaly 2: Non-Repeatable Read

**What happens:** Within the same transaction, reading the same row twice gives different results because another transaction committed a change between the two reads.

```
Timeline:
  T1                                T2
  BEGIN
  SELECT balance FROM acct WHERE id=1
  → 1000

                                    BEGIN
                                    UPDATE acct SET balance=500 WHERE id=1
                                    COMMIT

  SELECT balance FROM acct WHERE id=1
  → 500 ← DIFFERENT value, same transaction
  COMMIT
```

This breaks a transaction's assumption of a stable snapshot of what it has read. If T1 was deciding whether to approve a withdrawal based on the first read, the second read may give a contradictory result.

**Prevented by:** Repeatable Read and above.

### Anomaly 3: Phantom Read

**What happens:** A transaction executes a range query twice. Between the executions, another transaction inserts (or deletes) rows that match the range condition. The second query returns different rows.

```
Timeline:
  T1                                        T2
  BEGIN
  SELECT * FROM orders WHERE amount > 100
  → [order 1, order 3]

                                            BEGIN
                                            INSERT INTO orders (id, amount) VALUES (5, 200)
                                            COMMIT

  SELECT * FROM orders WHERE amount > 100
  → [order 1, order 3, order 5]  ← PHANTOM row appeared
  COMMIT
```

Phantoms are worse than non-repeatable reads because they involve not just modified rows but *new* rows that didn't exist during the first read. A predicate lock (lock on the *range*, not the row) is needed to prevent them, which is expensive.

**Prevented by:** Serializable (true serializable). Repeatable Read in most implementations prevents it for existing rows but not for insertions (phantom inserts can still appear in some engines).

> Note: Postgres's "Repeatable Read" is actually implemented as snapshot isolation, which also prevents phantoms in practice — but the SQL standard does not require Repeatable Read to prevent phantoms. This distinction matters when comparing engines.

### Anomaly 4: Write Skew

**What happens:** Two transactions each read an overlapping set of rows to check a condition, both conclude the condition allows them to proceed, and both write to different rows. Together their writes violate the invariant the condition was checking.

Classic example: an on-call scheduling system.

```sql
-- Invariant: at least one doctor must be on call at all times.
-- Currently: Alice is_on_call=true, Bob is_on_call=true (both on call)

-- T1 (Alice requests to go off call):
BEGIN;
SELECT COUNT(*) FROM doctors WHERE is_on_call = true;  -- → 2 (safe to remove one)
UPDATE doctors SET is_on_call = false WHERE name = 'Alice';
COMMIT;

-- T2 (Bob requests to go off call, concurrent with T1):
BEGIN;
SELECT COUNT(*) FROM doctors WHERE is_on_call = true;  -- → 2 (also sees 2, safe!)
UPDATE doctors SET is_on_call = false WHERE name = 'Bob';
COMMIT;

-- Result: COUNT=0. No doctor on call. Invariant violated.
-- Neither T1 nor T2 violated any constraint individually. The violation
-- only appears when you look at the combined effect.
```

Write skew is subtle because each transaction is individually correct. It arises because the *predicate* read (COUNT(*) WHERE ...) is not locked against concurrent modifications.

**Prevented by:** Serializable only. Neither Read Committed nor Repeatable Read/Snapshot Isolation prevents write skew.

### Anomaly 5: Lost Update

**What happens:** Two transactions read the same value, both compute a new value based on the read, and both write back. One write overwrites the other, losing its increment.

```
Timeline (read-modify-write without locking):
  T1                            T2
  SELECT count FROM widgets     SELECT count FROM widgets
  → 10                          → 10
  count = 10 + 1 = 11           count = 10 + 1 = 11
  UPDATE widgets SET count=11   UPDATE widgets SET count=11
  COMMIT                        COMMIT

Final: count = 11. Should be 12.
```

**Prevented by:**
- Repeatable Read (some engines detect and abort one of the conflicting transactions)
- Serializable
- Atomic operations: `UPDATE widgets SET count = count + 1` (the database handles the read-modify-write atomically within a single statement)
- Explicit locking: `SELECT ... FOR UPDATE`

**The atomic `UPDATE` fix** is what you should use 90% of the time in application code. It sidesteps the anomaly entirely at the statement level.

### Anomaly 6: Dirty Write

**What happens:** Transaction T1 writes a value. Before T1 commits or aborts, Transaction T2 overwrites that value. T1 then commits — but T2 has already changed what T1 wrote, or T1 aborts — but the UNDO log now rolls back T2's work too.

Dirty writes are prevented by **all isolation levels** (even Read Uncommitted does not permit dirty writes — row-level locks are always held until commit). This is why Row-level locking is not optional.

---

## The Anomaly-Level Matrix

```
                   ┌─────────────────────────────────────────────────────────────────┐
                   │         Isolation Level                                          │
                   ├────────────────┬──────────────┬──────────────┬──────────────────┤
Anomaly            │ Read           │ Read         │ Repeatable   │ Serializable     │
                   │ Uncommitted    │ Committed    │ Read         │                  │
───────────────────┼────────────────┼──────────────┼──────────────┼──────────────────┤
Dirty Write        │ PREVENTED      │ PREVENTED    │ PREVENTED    │ PREVENTED        │
Dirty Read         │ ALLOWED        │ PREVENTED    │ PREVENTED    │ PREVENTED        │
Non-Rep. Read      │ ALLOWED        │ ALLOWED      │ PREVENTED    │ PREVENTED        │
Phantom Read       │ ALLOWED        │ ALLOWED      │ ALLOWED*     │ PREVENTED        │
Lost Update        │ ALLOWED        │ ALLOWED      │ PREVENTED†   │ PREVENTED        │
Write Skew         │ ALLOWED        │ ALLOWED      │ ALLOWED      │ PREVENTED        │
───────────────────┴────────────────┴──────────────┴──────────────┴──────────────────┘
* Postgres's Repeatable Read (snapshot isolation) prevents phantoms in practice but the
  SQL standard permits them at this level.
† Some engines (Postgres) detect lost updates under Repeatable Read and abort the loser.
```

This matrix is the most important table in this module. Memorize it.

---

## Snapshot Isolation (SI)

Snapshot Isolation is not in the original SQL standard but is the implementation used by Postgres (for Read Committed and Repeatable Read), Oracle (Serializable label, confusingly), and most modern databases.

**The idea:** At the start of a transaction, take a *snapshot* of the database — a consistent point-in-time view. All reads within the transaction see only the data as of that snapshot, regardless of concurrent commits. Writes still go to the live database.

```
T1 snapshot taken at T=100 (xmin):
  Reads see only rows committed before T=100
  Rows committed by concurrent transactions (T > 100) are invisible to T1
  T1's own writes are visible to itself (read your own writes)
```

In Postgres, this is implemented via **MVCC** (Multi-Version Concurrency Control — covered in Module 04). Each row version carries `xmin` (transaction that inserted it) and `xmax` (transaction that deleted/updated it). A read at snapshot T=100 sees row versions where `xmin <= 100` and either `xmax > 100` or `xmax is null`.

### What Snapshot Isolation Does Not Prevent: Write Skew

Snapshot isolation prevents all read anomalies because reads are from a frozen snapshot. But it does **not** prevent write skew, because two transactions can each see a consistent snapshot (no anomaly in either transaction individually) but together violate a cross-transaction invariant.

The doctor example above happens under snapshot isolation: both T1 and T2 read COUNT=2 from their respective snapshots and proceed to write. Neither is "wrong" within its snapshot — but together they violate the invariant.

### Serializable Snapshot Isolation (SSI)

Serializable Snapshot Isolation (Cahill et al., 2008) extends snapshot isolation to also detect write skew. It does this by tracking **read-write dependencies** between transactions:

- If T1 reads a value and T2 later modifies that value (anti-dependency: T1 →rw T2)
- And T2 reads a value that T1 later modifies (anti-dependency: T2 →rw T1)
- And both T1 and T2 commit

Then this is a **dangerous cycle** — the execution is not serializable. SSI detects this pattern and aborts one transaction.

Postgres has used SSI since version 9.1 as its `SERIALIZABLE` implementation. It is not lock-based (no shared or predicate locks held throughout) — it uses lightweight SIREAD locks and conflict detection. The overhead is typically 10–20% vs snapshot isolation in practice.

---

## When to Use Which Isolation Level

This is the practical question. The theory is clear; the decision is nuanced.

### Read Committed (default in Postgres, MySQL READ COMMITTED)

Use when:
- Reads are used for display only and a slightly stale value is acceptable (a dashboard showing a balance that is 50ms stale).
- Your write patterns use atomic SQL operations (`UPDATE ... SET count = count + 1`) rather than read-modify-write in application code.
- You accept that a single transaction may see different values across two reads of the same row.

Risk: Non-repeatable reads are possible. If your transaction reads a row, makes a decision, then re-reads and acts again, the second read may give different results than the first.

### Repeatable Read (Postgres `REPEATABLE READ`, MySQL default)

Use when:
- A transaction reads multiple rows and needs a consistent view across all of them for its duration (e.g., generating a report, summing a set of balances).
- You want lost update protection on individual rows.

Risk: Write skew is still possible. If your invariant spans multiple rows (the on-call doctor example), Repeatable Read will not protect you.

### Serializable (Postgres `SERIALIZABLE`, MySQL `SERIALIZABLE`)

Use when:
- Invariants span multiple rows and cannot be expressed as a single `UPDATE` or CHECK constraint.
- The correctness of the application requires that the execution history is equivalent to some serial order (i.e., no write skew).
- Throughput is less important than correctness.

Cost: Postgres SSI is remarkably cheap (10–20% overhead). MySQL's serializable is lock-based and much more expensive (2-phase locking with shared locks on every SELECT — devastating for read-heavy workloads).

### The Common Mistake

Many developers set `READ COMMITTED` everywhere (the default) and then try to fix write skew with application-level optimistic concurrency or version columns. This works but puts the burden on the developer to correctly identify every invariant and add the right check. Postgres `SERIALIZABLE` is often the simpler and more correct choice — and cheaper than people expect.

---

## Worked Example: Diagnosing Write Skew in Production

You have a booking system with this invariant: a conference room cannot be double-booked.

```sql
CREATE TABLE bookings (
    room_id INT,
    start_ts TIMESTAMPTZ,
    end_ts TIMESTAMPTZ,
    booker TEXT
);

-- Application checks for conflicts before inserting:
-- "No booking for this room overlaps with the requested time range"
BEGIN;
SELECT COUNT(*) FROM bookings
WHERE room_id = 5
  AND tstzrange(start_ts, end_ts) && tstzrange('10:00', '11:00');
-- → 0 (no conflict)

INSERT INTO bookings VALUES (5, '10:00', '11:00', 'alice');
COMMIT;
```

If two users run this logic concurrently under `READ COMMITTED` or even `REPEATABLE READ`, both see COUNT=0, both insert, and the room is double-booked. This is write skew — two individually valid transactions violating a multi-row invariant.

**Fix 1: Serializable isolation.**
```sql
SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL SERIALIZABLE;
```
PostgreSQL's SSI will detect the anti-dependency and abort one transaction with `ERROR: could not serialize access due to read/write dependencies among transactions`. The application retries the aborted transaction.

**Fix 2: Explicit lock (`SELECT ... FOR UPDATE` or `LOCK TABLE`).**
```sql
BEGIN;
LOCK TABLE bookings IN SHARE ROW EXCLUSIVE MODE;
-- Now no other transaction can insert until we commit.
SELECT COUNT(*) ...;
INSERT ...;
COMMIT;
```
Heavy-handed but predictable. Suitable when write skew is rare and locking overhead is acceptable.

**Fix 3: Exclusion constraint (Postgres-specific).**
```sql
-- Requires the btree_gist extension
CREATE EXTENSION btree_gist;
ALTER TABLE bookings ADD CONSTRAINT no_overlap
    EXCLUDE USING gist (
        room_id WITH =,
        tstzrange(start_ts, end_ts) WITH &&
    );
```
The database enforces the invariant at the constraint level — no application code required. This is the cleanest solution when PostgreSQL is your database.

---

## Worked Example: Non-Repeatable Read Causing an Incorrect Balance Transfer

```python
# Application code using READ COMMITTED (the bug):
def transfer(conn, from_id, to_id, amount):
    with conn.transaction():
        # Read 1: check sender has enough
        row = conn.execute("SELECT balance FROM accounts WHERE id=?", from_id).fetchone()
        if row["balance"] < amount:
            raise ValueError("insufficient funds")
        # At this point, another transaction commits and reduces sender's balance.
        # Read 2: deduct
        conn.execute("UPDATE accounts SET balance=balance-? WHERE id=?", amount, from_id)
        conn.execute("UPDATE accounts SET balance=balance+? WHERE id=?", amount, to_id)
```

Under `READ COMMITTED`, the SELECT and the UPDATE see different snapshots. If another transaction reduced the balance between the two statements, the check in Python saw the old value and passed, but the UPDATE ran against the already-modified balance, potentially going negative.

**Fix:** Use an atomic UPDATE with a condition check:

```sql
UPDATE accounts SET balance = balance - $1 WHERE id = $2 AND balance >= $1;
-- Check affected_rows == 1. If 0, the balance was insufficient.
```

This is a single statement — no gap for concurrent modification. The check and update are atomic within one operation.

---

## Debugging Isolation-Level Issues in Production

### Identifying an Anomaly

**Symptom:** Balance occasionally goes negative despite application-level checks.

1. Check isolation level in use:
   ```sql
   SHOW default_transaction_isolation;
   -- On Postgres: likely 'read committed'
   ```

2. Look for concurrent read-modify-write patterns in your codebase:
   ```
   grep -rn "SELECT.*balance" app/
   # followed by application logic then UPDATE
   ```

3. Reproduce with two concurrent sessions:
   ```sql
   -- Session 1:            -- Session 2:
   BEGIN;                   BEGIN;
   SELECT balance...        SELECT balance...
   -- both see 100
                            UPDATE balance = 50; COMMIT;
   UPDATE balance = 50...   -- Session 2 committed first
   COMMIT;
   -- balance is now 50, not 0 or rejected
   ```

### Picking the Right Level for an Existing Application

Upgrading isolation level requires understanding your retry logic:
- `SERIALIZABLE`: application MUST handle `ERROR 40001 (serialization failure)` and retry. If your framework does not handle this, a serialization failure will surface as an unhandled exception.
- `REPEATABLE READ`: Postgres aborts lost-update losers with `ERROR 40001` as well. Same retry requirement.

**Testing approach:** Enable `log_min_duration_statement=0` and a transaction duration histogram. Then raise isolation level in a non-production environment and run load tests. Watch for `40001` errors in logs. Measure throughput difference.

Typical findings:
- OLTP with atomic UPDATE patterns: near-zero overhead from `REPEATABLE READ`.
- OLTP with application read-modify-write: `SERIALIZABLE` causes 5–30% retry overhead at high concurrency. This is usually acceptable.
- Reporting/analytics: `REPEATABLE READ` or `SERIALIZABLE` for consistency; the snapshot is stable for the duration of the report.

---

## Checkpoint

You are ready for the challenges when you can, without notes:

1. State the precise definition of each ACID property in one sentence. Not the vague hand-wave — the precise guarantee.
2. Give a concrete SQL example of a dirty read and explain why it is harmful.
3. Distinguish non-repeatable reads from phantom reads. Under which level is each prevented?
4. Reproduce the on-call doctor write skew scenario with SQL. Name the specific anomaly and state which isolation level prevents it.
5. Explain why snapshot isolation prevents dirty reads, non-repeatable reads, and phantoms, but not write skew.
6. State what SSI (Serializable Snapshot Isolation) detects that SI does not. What is the name for the pattern it detects?
7. Name the two error codes (Postgres) that indicate a serialization or lost-update conflict, and state what the application must do when it receives them.
8. Write the correct SQL for an atomic read-modify-write balance deduction that avoids the non-repeatable read problem without requiring `SERIALIZABLE`.
9. Describe the exclusion constraint approach to preventing double-booking and when it is preferable to `SERIALIZABLE`.

➡ Next: **Module 04 — Concurrency Control** — the machinery that actually enforces isolation: 2PL, MVCC, deadlock detection, and long-transaction vacuum bloat.
