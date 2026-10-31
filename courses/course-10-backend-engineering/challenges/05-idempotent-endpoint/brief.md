# Idempotent Endpoint

A Stripe-style payment service launched last quarter. This week the on-call pager fired at 3 AM: *"We charged customer 8821 twice. Post-mortem shows our mobile client retried a timed-out POST /orders — the server processed both."*

Root cause: the endpoint is not idempotent. A retry creates a duplicate. The fix: honour an `X-Idempotency-Key` header — if the same key is seen twice, return the cached first response and do nothing else.

## Why idempotency keys?

Networks are unreliable. Clients retry on timeout. Without idempotency:

```
client → POST /orders      ← server processes, writes to DB, response lost in transit
client → POST /orders      ← server processes AGAIN, duplicate charge
```

With idempotency keys:

```
client → POST /orders (key: uuid-A)  ← server processes, caches response under uuid-A
client → POST /orders (key: uuid-A)  ← server returns cached response, no second write
```

## Mission

Open `$HOME/.kube-dojo-work/05-idempotent-endpoint/main.py` and implement the two `TODO` blocks inside `create_order`.

The verifier passes only when **all four pytest cases pass**:

1. **`test_same_key_returns_same_response`** — two POSTs with the same `X-Idempotency-Key` must return an identical response body.
2. **`test_same_key_side_effect_once`** — three POSTs with the same key must create exactly **one** entry in `app_module.orders`.
3. **`test_different_keys_each_create_order`** — two POSTs with different keys must each create a separate order with different IDs.
4. **`test_no_key_always_creates_order`** — two POSTs without any key must each create a new order (no deduplication).

## Setup

```bash
bash courses/course-10-backend-engineering/challenges/05-idempotent-endpoint/setup.sh
cd $HOME/.kube-dojo-work/05-idempotent-endpoint
python3 -m venv .venv && source .venv/bin/activate && pip install fastapi pytest httpx
```

## Rules

- Edit only `main.py`. Do not modify `test_idempotency.py`.
- The test harness clears `app_module.orders` and `app_module._idem_cache` between tests — rely on those names exactly.
- Do not change the function signature of `create_order`.

When all tests are green, run the verifier:

```bash
bash courses/course-10-backend-engineering/challenges/05-idempotent-endpoint/verify.sh
```
