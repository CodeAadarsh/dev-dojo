#!/usr/bin/env bash
# Plants the "Break and Fix: IDOR in an Order API" project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/06-break-and-fix-auth"
mkdir -p "$WORK/tests"

# ── app.py — vulnerable FastAPI app ──────────────────────────────────────────
cat > "$WORK/app.py" << 'PYEOF'
# app.py — DELIBERATELY VULNERABLE order API.
# Bug: GET /orders/{order_id} authenticates the caller but never checks ownership.
# Fix: add an ownership check so a user can only read their own orders (403 otherwise).
from fastapi import FastAPI, Depends, HTTPException, Header
from typing import Optional

app = FastAPI()

# Simulated token store: token -> username
TOKENS = {
    "token-a": "alice",
    "token-b": "bob",
}

# Simulated order store: order_id -> {"owner": str, "item": str}
ORDERS = {
    1: {"owner": "alice", "item": "Laptop"},
    2: {"owner": "bob",   "item": "Keyboard"},
    3: {"owner": "alice", "item": "Monitor"},
}


def get_current_user(authorization: Optional[str] = Header(None)) -> str:
    """Resolve the Bearer token to a username; 401 if missing or invalid."""
    if authorization is None or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing or invalid token")
    token = authorization.removeprefix("Bearer ")
    user = TOKENS.get(token)
    if user is None:
        raise HTTPException(status_code=401, detail="Invalid token")
    return user


@app.get("/orders/{order_id}")
def get_order(order_id: int, current_user: str = Depends(get_current_user)):
    order = ORDERS.get(order_id)
    if order is None:
        raise HTTPException(status_code=404, detail="Order not found")
    # BUG: ownership check missing here.
    # Any authenticated user can read any order.
    return {"order_id": order_id, **order}


@app.get("/orders")
def list_my_orders(current_user: str = Depends(get_current_user)):
    """Return only the caller's own orders — this endpoint is already correct."""
    return [
        {"order_id": oid, **o}
        for oid, o in ORDERS.items()
        if o["owner"] == current_user
    ]
PYEOF

# ── tests/test_leak.py — demonstrates the bug (passes on vulnerable code) ────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_leak.py" << 'PYEOF'
# test_leak.py — demonstrates the IDOR vulnerability.
# This test PASSES on the unpatched app (the leak is real).
# After your fix, this test should FAIL (the bug is gone).
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastapi.testclient import TestClient
from app import app

client = TestClient(app, raise_server_exceptions=False)

BOB_HEADERS = {"Authorization": "Bearer token-b"}


def test_bob_can_read_alices_order_IDOR():
    """Bob reads alice's order 1 — this should NOT be allowed, but it is (bug)."""
    r = client.get("/orders/1", headers=BOB_HEADERS)
    # On the vulnerable app this is 200; after your fix it must be 403.
    assert r.status_code == 200, (
        f"Expected 200 on vulnerable app, got {r.status_code}. "
        "If you see 403, the bug is already fixed — run verify.sh."
    )
PYEOF

# ── tests/test_fix.py — asserts correct behaviour (fails on vulnerable code) ─
cat > "$WORK/tests/test_fix.py" << 'PYEOF'
# test_fix.py — asserts the corrected access-control behaviour.
# This test FAILS on the unpatched app.
# After your fix, it should PASS.
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastapi.testclient import TestClient
from app import app

client = TestClient(app, raise_server_exceptions=False)

ALICE_HEADERS = {"Authorization": "Bearer token-a"}
BOB_HEADERS   = {"Authorization": "Bearer token-b"}


def test_alice_reads_own_order_200():
    r = client.get("/orders/1", headers=ALICE_HEADERS)
    assert r.status_code == 200, f"alice should read her own order, got {r.status_code}"


def test_alice_reads_bobs_order_403():
    r = client.get("/orders/2", headers=ALICE_HEADERS)
    assert r.status_code == 403, f"alice must not read bob's order (IDOR), got {r.status_code}"


def test_bob_reads_own_order_200():
    r = client.get("/orders/2", headers=BOB_HEADERS)
    assert r.status_code == 200, f"bob should read his own order, got {r.status_code}"


def test_bob_reads_alices_order_403():
    r = client.get("/orders/1", headers=BOB_HEADERS)
    assert r.status_code == 403, f"bob must not read alice's order (IDOR), got {r.status_code}"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "The app is planted with a deliberate IDOR bug in GET /orders/{order_id}."
echo
echo "Step 1  — see the bug:"
echo "  cd $WORK && .venv/bin/pytest tests/test_leak.py -v"
echo
echo "Step 2  — fix app.py (add the ownership check)"
echo
echo "Step 3  — confirm the fix:"
echo "  .venv/bin/pytest tests/test_fix.py -v"
echo
echo "Step 4  — run the verifier:"
echo "  bash courses/course-16-security-auth/challenges/06-break-and-fix-auth/verify.sh"
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install fastapi pytest httpx"
