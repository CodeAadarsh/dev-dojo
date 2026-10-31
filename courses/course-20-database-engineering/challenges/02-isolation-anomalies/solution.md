# Solution — Isolation Anomalies — Stop the Lost Update

The entire fix is a two-word addition: append `FOR UPDATE` to the `SELECT` inside `deposit()`.

```python
# fix.py — corrected deposit()
import psycopg2
import time
from contextlib import contextmanager
from typing import Generator

DSN = "dbname=dojo user=postgres host=localhost port=5432 password=postgres"


@contextmanager
def _transaction() -> Generator:
    conn = psycopg2.connect(DSN)
    conn.autocommit = False
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def deposit(account_id: int, amount: int) -> None:
    with _transaction() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT balance FROM accounts WHERE id = %s FOR UPDATE",  # ← the fix
                (account_id,),
            )
            row = cur.fetchone()
            if row is None:
                raise ValueError(f"account {account_id} not found")
            balance = row[0]
            time.sleep(0.02)
            cur.execute(
                "UPDATE accounts SET balance = %s WHERE id = %s",
                (balance + amount, account_id),
            )
```

## Why `FOR UPDATE` prevents the lost update

`SELECT ... FOR UPDATE` acquires a **row-level exclusive lock** on the matched rows for the duration of the current transaction. The lock is released when the transaction commits or rolls back.

```
  Time →

  Thread A (with FOR UPDATE)       Thread B (with FOR UPDATE)
  ─────────────────────────────────────────────────────────────
  BEGIN
  SELECT balance = 1000 FOR UPDATE ← acquires lock on row id=1
                                   BEGIN
                                   SELECT ... FOR UPDATE ← BLOCKS (row locked by A)
  new = 1000 + 100 = 1100
  UPDATE balance = 1100
  COMMIT  (lock released)
                                   ← unblocks, reads committed value 1100
                                   new = 1100 + 100 = 1200
                                   UPDATE balance = 1200
                                   COMMIT

  Final balance: 1200 ✓
```

Thread B does not proceed past the `SELECT` until Thread A commits. When it does, it reads the *post-commit* value (1100), so its write produces 1200, not 1100.

## Why `READ COMMITTED` alone is not enough

The default PostgreSQL isolation level, `READ COMMITTED`, guarantees that each *statement* sees only committed rows. It does **not** guarantee that the values you read remain stable while your transaction is running. Two concurrent read-then-write operations on the same row are fully compliant with `READ COMMITTED` even if they clobber each other — the engine never sees a conflict.

`FOR UPDATE` is an explicit, application-side concurrency primitive layered on top of isolation. It is the correct tool when your code pattern is:
1. Read a value.
2. Compute a new value based on the read.
3. Write the new value back.

That pattern is inherently racy without locking, regardless of isolation level.

## Alternative: SERIALIZABLE isolation

```python
conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_SERIALIZABLE)
```

Under `SERIALIZABLE`, Postgres detects the anomaly and aborts one of the concurrent transactions with `ERROR 40001: could not serialize access due to concurrent update`. The caller must catch this error and retry. This is correct but requires retry logic in the application — more lines, more surface area for bugs.

`FOR UPDATE` is the simpler, more targeted fix for this specific pattern.

## Apply and verify

```bash
cd ~/.kube-dojo-work/02-isolation-anomalies
# edit fix.py: add FOR UPDATE to the SELECT, then:
.venv/bin/pytest tests/ -v
bash courses/course-20-database-engineering/challenges/02-isolation-anomalies/verify.sh
```
