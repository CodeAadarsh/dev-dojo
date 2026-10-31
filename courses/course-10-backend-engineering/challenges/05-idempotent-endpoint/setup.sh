#!/usr/bin/env bash
# Plants the idempotent endpoint challenge: FastAPI skeleton + pytest harness.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/05-idempotent-endpoint"
mkdir -p "$WORK"

# --- skeleton: main.py ---
cat > "$WORK/main.py" << 'PYEOF'
# main.py — FastAPI orders service; implement the idempotency logic marked TODO
from __future__ import annotations
import uuid
from typing import Optional
from fastapi import FastAPI, Header, Request

app = FastAPI()

# In-memory stores; the test harness resets these between test cases.
orders: dict = {}          # order_id -> order payload
_idem_cache: dict = {}    # idempotency_key -> cached response dict


@app.post("/orders")
async def create_order(
    request: Request,
    x_idempotency_key: Optional[str] = Header(default=None),
) -> dict:
    body = await request.json()

    # TODO: if x_idempotency_key is not None and already in _idem_cache,
    #       return the cached response — do NOT create a new order.

    order_id = str(uuid.uuid4())
    orders[order_id] = body
    response = {"id": order_id, "status": "created"}

    # TODO: if x_idempotency_key is not None, store response in _idem_cache
    #       before returning, so future calls with the same key are deduplicated.

    return response
PYEOF

# --- test harness: test_idempotency.py (do not edit) ---
cat > "$WORK/test_idempotency.py" << 'PYEOF'
# test_idempotency.py — DO NOT EDIT; this is the verifier harness
import main as app_module
from fastapi.testclient import TestClient


def _fresh() -> TestClient:
    """Reset all in-memory state and return a clean TestClient."""
    app_module.orders.clear()
    app_module._idem_cache.clear()
    return TestClient(app_module.app)


def test_same_key_returns_same_response():
    client = _fresh()
    payload = {"item": "widget", "qty": 1}
    key = "idem-abc-001"

    r1 = client.post("/orders", json=payload, headers={"X-Idempotency-Key": key})
    r2 = client.post("/orders", json=payload, headers={"X-Idempotency-Key": key})

    assert r1.status_code == 200 and r2.status_code == 200
    assert r1.json() == r2.json(), (
        "Identical Idempotency-Key must return the same response body.\n"
        f"  call 1: {r1.json()}\n  call 2: {r2.json()}"
    )


def test_same_key_side_effect_once():
    client = _fresh()
    payload = {"item": "gadget", "qty": 2}
    key = "idem-abc-002"

    client.post("/orders", json=payload, headers={"X-Idempotency-Key": key})
    client.post("/orders", json=payload, headers={"X-Idempotency-Key": key})
    client.post("/orders", json=payload, headers={"X-Idempotency-Key": key})

    assert len(app_module.orders) == 1, (
        f"Side effect (order creation) must happen exactly once, "
        f"got {len(app_module.orders)} entries in orders"
    )


def test_different_keys_each_create_order():
    client = _fresh()
    payload = {"item": "thingamajig", "qty": 5}

    r1 = client.post("/orders", json=payload, headers={"X-Idempotency-Key": "key-A"})
    r2 = client.post("/orders", json=payload, headers={"X-Idempotency-Key": "key-B"})

    assert r1.status_code == 200 and r2.status_code == 200
    assert r1.json()["id"] != r2.json()["id"], (
        "Different idempotency keys must yield different order IDs"
    )
    assert len(app_module.orders) == 2, (
        f"Two different keys must create two orders, got {len(app_module.orders)}"
    )


def test_no_key_always_creates_order():
    client = _fresh()
    payload = {"item": "doohickey", "qty": 1}

    r1 = client.post("/orders", json=payload)
    r2 = client.post("/orders", json=payload)

    assert r1.status_code == 200 and r2.status_code == 200
    assert r1.json()["id"] != r2.json()["id"], (
        "Calls without X-Idempotency-Key must never be deduplicated"
    )
    assert len(app_module.orders) == 2, (
        f"Two calls without a key must create two orders, got {len(app_module.orders)}"
    )
PYEOF

echo
echo "Work directory: $WORK"
echo
echo "Files written:"
echo "  main.py              — FastAPI skeleton; implement the two TODO blocks"
echo "  test_idempotency.py  — verifier harness (do not edit)"
echo
echo "Task:"
echo "  Implement idempotency-key handling in main.py:"
echo "  1. Before creating an order, check _idem_cache for x_idempotency_key."
echo "     If found, return the cached response immediately."
echo "  2. After creating an order, store the response in _idem_cache if a key was given."
echo
echo "Prereqs (run inside $WORK):"
echo "  python3 -m venv .venv && source .venv/bin/activate && pip install fastapi pytest httpx"
echo
echo "Run tests:"
echo "  cd $WORK && .venv/bin/python -m pytest test_idempotency.py -v"
