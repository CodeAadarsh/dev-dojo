#!/usr/bin/env bash
# Verifier for "CRUD API with Status Codes".
# Runs a hidden pytest harness against the learner's main.py.
# Prints the flag only when all tests pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/01-crud-api"
FLAG='KUBE{fastapi_crud_status_codes}'

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

cat > "$HIDDEN_DIR/test_crud.py" << 'PYEOF'
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

def test_create_returns_201():
    r = client.post("/items", json={"name": "Wrench", "price": 12.99})
    assert r.status_code == 201, f"POST /items must return 201, got {r.status_code}"
    body = r.json()
    assert "id" in body
    assert body["name"] == "Wrench"

def test_create_assigns_unique_ids():
    r1 = client.post("/items", json={"name": "A", "price": 1.0})
    r2 = client.post("/items", json={"name": "B", "price": 2.0})
    assert r1.status_code == 201
    assert r2.status_code == 201
    assert r1.json()["id"] != r2.json()["id"]

def test_list_returns_200_list():
    client.post("/items", json={"name": "X", "price": 1.0})
    r = client.get("/items")
    assert r.status_code == 200
    assert isinstance(r.json(), list)
    assert len(r.json()) >= 1

def test_get_existing_item():
    create = client.post("/items", json={"name": "Widget", "description": "blue", "price": 5.0})
    assert create.status_code == 201
    item_id = create.json()["id"]
    r = client.get(f"/items/{item_id}")
    assert r.status_code == 200
    assert r.json()["description"] == "blue"

def test_get_missing_returns_404():
    r = client.get("/items/999999")
    assert r.status_code == 404

def test_update_item_returns_200():
    create = client.post("/items", json={"name": "Old", "price": 3.0})
    assert create.status_code == 201
    item_id = create.json()["id"]
    r = client.put(f"/items/{item_id}", json={"name": "New", "price": 6.0})
    assert r.status_code == 200
    assert r.json()["name"] == "New"

def test_update_missing_returns_404():
    r = client.put("/items/999999", json={"name": "X", "price": 1.0})
    assert r.status_code == 404

def test_delete_returns_204():
    create = client.post("/items", json={"name": "Trash", "price": 0.01})
    assert create.status_code == 201
    item_id = create.json()["id"]
    r = client.delete(f"/items/{item_id}")
    assert r.status_code == 204

def test_delete_missing_returns_404():
    r = client.delete("/items/999999")
    assert r.status_code == 404

def test_deleted_item_not_in_list():
    create = client.post("/items", json={"name": "Gone", "price": 1.0})
    assert create.status_code == 201
    item_id = create.json()["id"]
    client.delete(f"/items/{item_id}")
    listing = client.get("/items")
    ids = [item["id"] for item in listing.json()]
    assert item_id not in ids
PYEOF

if WORK_DIR="$WORK" $PYTEST "$HIDDEN_DIR/test_crud.py" -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix your implementation and retry"
fi
