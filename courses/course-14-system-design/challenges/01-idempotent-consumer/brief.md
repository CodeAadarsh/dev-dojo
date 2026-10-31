# Idempotent Message Consumer

Your on-call shift, 2am. The payments team just filed a P1: customers are receiving double refunds during peak load. The root cause is already known — the message broker redelivers messages when the consumer crashes after writing to the DB but before acknowledging the message, and your consumer has no deduplication guard.

The fix is straightforward to describe and deceptively easy to get wrong: store an idempotency key **in the same database transaction as the side effect**, using a unique constraint as the guard. If the key already exists, skip the side effect and return success silently.

## Mission

Implement `consumer.py` in `~/.kube-dojo-work/01-idempotent-consumer/` with:

```python
def process_message(conn: sqlite3.Connection, message: dict) -> bool:
    """
    Process a message idempotently.

    message has keys:
      - idempotency_key (str): a UUID; stable across redeliveries of the same message
      - account_id (int): target account
      - amount (int): amount in paise to credit (always positive)

    Returns True if the message was processed (first time).
    Returns False if the message was a duplicate (already processed).

    The function MUST:
    1. Check whether idempotency_key already exists in the processed_messages table.
    2. If duplicate: return False without touching the accounts table.
    3. If new: insert the key AND update accounts.balance in the SAME transaction.
       Both writes must commit together or not at all.
    """
```

The schema is already created by `setup.sh`. The verifier checks:

1. A fresh message credits the account and inserts the key.
2. Redelivering the same message (same `idempotency_key`) changes neither the balance nor the key count.
3. Two different messages with different keys both succeed (no over-blocking).
4. A crash-and-redelivery scenario: the function is called twice before any commit; only one effect lands.
5. Concurrent redeliveries do not double-credit (the unique constraint must be the guard, not application-level pre-check).

## Why this matters

The naive implementation does `SELECT count(*) FROM processed_messages WHERE key = ?` and only inserts if count is zero. That's a check-then-act race: two concurrent calls both see count=0, both proceed, both credit the account. The correct implementation lets the **unique constraint** be the guard — let the database serialize the conflict — and catches the `UNIQUE constraint failed` exception to return False.
