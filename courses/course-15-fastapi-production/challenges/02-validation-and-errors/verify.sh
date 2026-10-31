#!/usr/bin/env bash
# Verifier for "Validation and Error Envelopes".
# Runs a hidden pytest harness; prints the flag only when all tests pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/02-validation-and-errors"
FLAG='KUBE{pydantic_guards_the_gate}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/main.py" ] || fail "main.py not found in $WORK"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install fastapi httpx pytest pydantic"
fi

# ── hidden test suite ─────────────────────────────────────────────────────────
HIDDEN_DIR="$(mktemp -d)"
trap 'rm -rf "$HIDDEN_DIR"' EXIT

cat > "$HIDDEN_DIR/test_validation.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.environ["WORK_DIR"])

import pytest
from fastapi.testclient import TestClient
from main import app, _store, _next_id

@pytest.fixture(autouse=True)
def reset_store():
    import main
    main._store.clear()
    main._next_id = 1
    yield
    main._store.clear()
    main._next_id = 1

client = TestClient(app)

# ── constraint tests ──────────────────────────────────────────────────────────

def test_empty_name_returns_422():
    r = client.post("/items", json={"name": "", "price": 10.0})
    assert r.status_code == 422, f"Empty name must return 422, got {r.status_code}"

def test_name_too_long_returns_422():
    long_name = "x" * 121
    r = client.post("/items", json={"name": long_name, "price": 10.0})
    assert r.status_code == 422, f"Name > 120 chars must return 422, got {r.status_code}"

def test_negative_price_returns_422():
    r = client.post("/items", json={"name": "Widget", "price": -1.0})
    assert r.status_code == 422, f"Negative price must return 422, got {r.status_code}"

def test_zero_price_returns_422():
    r = client.post("/items", json={"name": "Widget", "price": 0.0})
    assert r.status_code == 422, f"Zero price must return 422, got {r.status_code}"

# ── envelope shape tests ──────────────────────────────────────────────────────

def test_422_content_type_is_json():
    r = client.post("/items", json={"name": "", "price": 10.0})
    assert r.status_code == 422
    ct = r.headers.get("content-type", "")
    assert ct.startswith("application/json"), (
        f"422 Content-Type must be application/json, got: {ct}"
    )

def test_422_body_has_status_field():
    r = client.post("/items", json={"name": "", "price": 10.0})
    assert r.status_code == 422
    body = r.json()
    assert body.get("status") == 422, (
        f"422 envelope must have 'status: 422', got: {body}"
    )

def test_422_body_has_error_field():
    r = client.post("/items", json={"name": "", "price": 10.0})
    body = r.json()
    assert "error" in body, f"422 envelope missing 'error' key, got: {body}"

def test_422_body_has_details_list():
    r = client.post("/items", json={"name": "", "price": 10.0})
    body = r.json()
    assert "details" in body, f"422 envelope missing 'details' key, got: {body}"
    assert isinstance(body["details"], list), "'details' must be a list"

def test_404_content_type_is_json():
    r = client.get("/items/999999")
    assert r.status_code == 404
    ct = r.headers.get("content-type", "")
    assert ct.startswith("application/json"), (
        f"404 Content-Type must be application/json, got: {ct}"
    )

def test_404_body_has_status_field():
    r = client.get("/items/999999")
    assert r.status_code == 404
    body = r.json()
    assert body.get("status") == 404, (
        f"404 envelope must have 'status: 404', got: {body}"
    )

def test_404_body_has_error_field():
    r = client.get("/items/999999")
    body = r.json()
    assert "error" in body, f"404 envelope missing 'error' key, got: {body}"

def test_404_body_has_message_field():
    r = client.get("/items/999999")
    body = r.json()
    assert "message" in body, f"404 envelope missing 'message' key, got: {body}"

def test_valid_item_still_returns_201():
    r = client.post("/items", json={"name": "Valid Item", "price": 9.99})
    assert r.status_code == 201, f"Valid POST /items must return 201, got {r.status_code}"
    body = r.json()
    assert body["name"] == "Valid Item"
PYEOF

if WORK_DIR="$WORK" $PYTEST "$HIDDEN_DIR/test_validation.py" -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix your implementation and retry"
fi
