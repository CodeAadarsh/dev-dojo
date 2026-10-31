# Solution — Idempotent Endpoint

The flag is `KUBE{idempotency_key_once_and_only_once}`.

## Correct implementation

```python
@app.post("/orders")
async def create_order(
    request: Request,
    x_idempotency_key: Optional[str] = Header(default=None),
) -> dict:
    body = await request.json()

    if x_idempotency_key and x_idempotency_key in _idem_cache:
        return _idem_cache[x_idempotency_key]

    order_id = str(uuid.uuid4())
    orders[order_id] = body
    response = {"id": order_id, "status": "created"}

    if x_idempotency_key:
        _idem_cache[x_idempotency_key] = response

    return response
```

## Why the ordering matters

Check the cache **before** creating the order, not after. If you create first and cache second, a concurrent retry that arrives between the create and the cache-write will slip through and create a duplicate. This is a classic TOCTOU window. In production it is closed with an **atomic INSERT with a unique constraint**:

```sql
-- Postgres pattern
INSERT INTO idempotency_keys (key, response)
VALUES ($1, $2)
ON CONFLICT (key) DO NOTHING
RETURNING response;
-- 0 rows returned = key already existed; fetch the existing row for the cached response
```

The database uniqueness constraint is the real guard; the in-memory dict is just a fast path.

## What the in-memory version gets wrong for production

| Problem | Fix |
|---------|-----|
| Not durable — restart loses the cache | Store keys in Postgres/Redis |
| Not shared across replicas — each pod has its own dict | Centralise in Redis or DB |
| No expiry — dict grows forever | Expire keys after 24 h (Stripe's policy) |
| No body mismatch detection | Compare request body to stored body; return 409 if different (client bug) |
| Not thread-safe — concurrent same-key requests can both miss the cache | Atomic DB insert or Redis `SET NX` |

## Stripe's model

Stripe's Charges and PaymentIntents APIs use idempotency keys across all mutating endpoints. Key behaviours:

1. Keys are accepted for 24 h, then expire (free old state).
2. A key reused with a *different* request body returns `400 Bad Request` — it almost always indicates a client bug where the same key was accidentally sent with a different payload.
3. Stripe stores the HTTP status code and body, not just the resource ID, so retries get the exact same response (including errors — if the first call returned a card-declined error, so does the retry).

## Idempotency vs at-most-once vs at-least-once

- **At-most-once**: fire and forget, no retry. Some requests may be lost. Acceptable for metrics/logging.
- **At-least-once**: retry until acknowledged. Without idempotency → duplicates. Kafka consumer groups work this way.
- **Exactly-once (idempotent)**: retry freely; deduplication on the server. This challenge. True exactly-once end-to-end (including the network) is provably impossible without two-phase commit or equivalent.
