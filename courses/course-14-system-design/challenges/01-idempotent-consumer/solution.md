# Solution: Idempotent Message Consumer

## The Core Insight

The naive pre-check pattern is a race condition:

```python
# WRONG — check-then-act race
if not conn.execute("SELECT 1 FROM processed_messages WHERE idempotency_key = ?", (key,)).fetchone():
    conn.execute("INSERT INTO processed_messages ...")
    conn.execute("UPDATE accounts SET balance = balance + ? WHERE id = ?", ...)
    conn.commit()
```

Two concurrent calls both execute the SELECT before either commits. Both see no existing key. Both proceed to insert. One succeeds; the other hits the UNIQUE constraint — but only if the INSERT and UPDATE are not already committed. This pattern is unreliable under concurrency.

The correct guard is the **unique constraint** itself. Attempt the insert; let the database serialize the conflict; catch `IntegrityError`.

## The Solution

```python
def process_message(conn: sqlite3.Connection, message: dict) -> bool:
    key = message["idempotency_key"]
    account_id = message["account_id"]
    amount = message["amount"]

    try:
        with conn:  # context manager: BEGIN on enter, COMMIT on exit, ROLLBACK on exception
            conn.execute(
                "INSERT INTO processed_messages (idempotency_key) VALUES (?)",
                (key,),
            )
            conn.execute(
                "UPDATE accounts SET balance = balance + ? WHERE id = ?",
                (amount, account_id),
            )
        return True
    except sqlite3.IntegrityError:
        # UNIQUE constraint failed — duplicate key; the whole transaction was rolled back
        return False
```

## Why This Works

1. `INSERT INTO processed_messages` will raise `IntegrityError` if the key already exists.
2. The `with conn:` context manager wraps both the INSERT and the UPDATE in a single transaction. If the INSERT raises, the UPDATE never executes. If the UPDATE fails (e.g., account not found), the INSERT is rolled back — no orphan key.
3. The unique constraint is the serialization point. Under concurrency, the database ensures exactly one insert wins; the loser gets `IntegrityError` and returns `False`.

## The Atomicity Invariant

```
processed_messages row  ⟺  accounts.balance credited
```

These two facts must always be in sync. The `with conn:` block guarantees it: both writes commit or neither does. This is why the idempotency key must live in the **same database** as the side effect — if the key were in Redis and the credit in Postgres, there is no shared transaction boundary and the invariant breaks.
