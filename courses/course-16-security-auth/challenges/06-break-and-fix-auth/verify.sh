#!/usr/bin/env bash
# Verifier for "Break and Fix: IDOR in an Order API".
# Runs the hidden pytest suite; prints the flag only when every check passes.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/06-break-and-fix-auth"
FLAG='KUBE{idor_fixed_check_owner_not_just_auth}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/app.py" ] || fail "app.py not found in $WORK"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install fastapi pytest httpx"
fi

# ── hidden test suite written inline ─────────────────────────────────────────
HIDDEN_TESTS=$(cat << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fastapi.testclient import TestClient
from app import app

client = TestClient(app, raise_server_exceptions=False)

ALICE = {"Authorization": "Bearer token-a"}
BOB   = {"Authorization": "Bearer token-b"}


# ── own-order access (must still be 200) ─────────────────────────────────────

def test_alice_own_order_200():
    r = client.get("/orders/1", headers=ALICE)
    assert r.status_code == 200, f"alice must read her own order, got {r.status_code}"

def test_alice_own_order_3_200():
    r = client.get("/orders/3", headers=ALICE)
    assert r.status_code == 200, f"alice must read her own order 3, got {r.status_code}"

def test_bob_own_order_200():
    r = client.get("/orders/2", headers=BOB)
    assert r.status_code == 200, f"bob must read his own order, got {r.status_code}"


# ── cross-user access (must be 403 after fix) ─────────────────────────────────

def test_alice_reads_bob_order_403():
    r = client.get("/orders/2", headers=ALICE)
    assert r.status_code == 403, \
        f"alice must not read bob's order (IDOR) — got {r.status_code}. Did you add the ownership check?"

def test_bob_reads_alice_order1_403():
    r = client.get("/orders/1", headers=BOB)
    assert r.status_code == 403, \
        f"bob must not read alice's order 1 (IDOR) — got {r.status_code}"

def test_bob_reads_alice_order3_403():
    r = client.get("/orders/3", headers=BOB)
    assert r.status_code == 403, \
        f"bob must not read alice's order 3 (IDOR) — got {r.status_code}"


# ── 404 for missing orders (must be unchanged) ───────────────────────────────

def test_missing_order_404():
    r = client.get("/orders/999", headers=ALICE)
    assert r.status_code == 404, f"missing order must 404, got {r.status_code}"


# ── unauthenticated access (must be 401) ─────────────────────────────────────

def test_no_token_401():
    r = client.get("/orders/1")
    assert r.status_code == 401, f"missing token must 401, got {r.status_code}"

def test_bad_token_401():
    r = client.get("/orders/1", headers={"Authorization": "Bearer bad-token"})
    assert r.status_code == 401, f"invalid token must 401, got {r.status_code}"


# ── list own orders still works ───────────────────────────────────────────────

def test_list_orders_alice():
    r = client.get("/orders", headers=ALICE)
    assert r.status_code == 200
    ids = {o["order_id"] for o in r.json()}
    assert 1 in ids and 3 in ids and 2 not in ids, \
        f"alice's order list is wrong: {ids}"

def test_list_orders_bob():
    r = client.get("/orders", headers=BOB)
    assert r.status_code == 200
    ids = {o["order_id"] for o in r.json()}
    assert 2 in ids and 1 not in ids, \
        f"bob's order list is wrong: {ids}"
PYEOF
)

HIDDEN_FILE="$WORK/tests/_hidden_idor_suite.py"
printf '%s\n' "$HIDDEN_TESTS" > "$HIDDEN_FILE"

if $PYTEST "$HIDDEN_FILE" -q 2>&1; then
    rm -f "$HIDDEN_FILE"
    echo
    echo "All access-control tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    rm -f "$HIDDEN_FILE"
    fail "test suite has failures — fix the ownership check in app.py and retry"
fi
