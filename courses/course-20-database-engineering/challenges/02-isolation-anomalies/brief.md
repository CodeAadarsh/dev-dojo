# Isolation Anomalies — Stop the Lost Update

The on-call incident: *"We ran a promotion last night. Two checkout workers processed the same account simultaneously and balance ended up as +$100 instead of +$200. Audit trail shows both read $1,000, both wrote $1,100. Classic lost update. Fix it before tonight's sale."*

> **Docker prerequisite:** this challenge requires the shared `dojo-pg` Postgres container to be running and accessible on `localhost:5432`. Start it with:
> ```bash
> docker run -d --name dojo-pg -e POSTGRES_PASSWORD=postgres \
>   -e POSTGRES_DB=dojo -p 5432:5432 postgres:16-alpine
> ```
> If it already exists: `docker start dojo-pg`

## The lost update — anatomy

```
  Time →

  Thread A                         Thread B
  ─────────────────────────────────────────────────
  BEGIN
  SELECT balance = 1000
                                   BEGIN
                                   SELECT balance = 1000
  new = 1000 + 100 = 1100
  UPDATE balance = 1100
  COMMIT
                                   new = 1000 + 100 = 1100
                                   UPDATE balance = 1100   ← OVERWRITES A's write
                                   COMMIT

  Final balance: 1100 ✗  (should be 1200)
```

Both transactions read the *same* stale snapshot before either commits. The second write clobbers the first. This is the **lost update** anomaly. It happens even at `READ COMMITTED` isolation because that level only guarantees you see committed data at each *statement*, not that nobody else commits between your read and your write.

## Why the default isolation level is not enough

PostgreSQL defaults to `READ COMMITTED`. Under `READ COMMITTED`, the sequence above is valid — Postgres sees no conflict because each transaction reads a consistent snapshot and writes a valid value. The concurrency problem is invisible to the engine without explicit locking.

The two canonical fixes:

| Fix | Mechanism | Trade-off |
|-----|-----------|-----------|
| `SELECT ... FOR UPDATE` | Row-level lock; second reader blocks until first transaction commits, then reads the committed value | Serializes access to this row; throughput scales with lock contention |
| `REPEATABLE READ` / `SERIALIZABLE` isolation | Postgres detects the anomaly and aborts one transaction with `ERROR 40001 serialization_failure` | Requires the caller to retry; correct but more complex error handling |

This challenge uses `SELECT ... FOR UPDATE` — it is simpler, more explicit, and the idiomatic fix for read-modify-write patterns in application code.

## Context

`setup.sh` seeds the `accounts` table and plants a starter project:

```
~/.kube-dojo-work/02-isolation-anomalies/
├── fix.py            # deposit() function — broken (lost-update bug)
└── tests/
    └── test_sample.py  # visible sample tests
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/02-isolation-anomalies
python3 -m venv .venv && . .venv/bin/activate
pip install psycopg2-binary pytest
```

## Mission

Edit `fix.py`. Change the `SELECT` inside `deposit()` from:

```sql
SELECT balance FROM accounts WHERE id = %s
```

to:

```sql
SELECT balance FROM accounts WHERE id = %s FOR UPDATE
```

That single clause turns a plain read into a **row-level exclusive lock**. The second concurrent caller blocks at the `SELECT` until the first transaction commits, then reads the *updated* balance — so `1100 + 100 = 1200` instead of `1000 + 100 = 1100`.

Do not change `get_balance_dsn`, `DSN`, or any other function signature — the verifier imports `deposit` directly.

### What the verifier checks

1. A direct (non-concurrent) `deposit(1, 100)` succeeds and increases balance by 100.
2. Two concurrent `deposit(1, 100)` calls run without exceptions.
3. The final balance after both concurrent deposits equals `starting_balance + 200` (no lost update).
4. `deposit` raises an exception if the account does not exist (no silent failure on missing row).

## Verify

```bash
bash courses/course-20-database-engineering/challenges/02-isolation-anomalies/verify.sh
```

All 4 hidden tests pass → flag printed.
