#!/usr/bin/env bash
# Plants the "Build a REST API" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/01-build-a-rest-api"
mkdir -p "$WORK/tests"

# ── main.py skeleton ────────────────────────────────────────────────────────
cat > "$WORK/main.py" << 'PYEOF'
# main.py — items CRUD skeleton
# Implement the five endpoint bodies. The models and in-memory store are ready;
# only the logic inside each function is stubbed with a 501 placeholder.
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Optional, List

app = FastAPI()


class ItemCreate(BaseModel):
    name: str
    description: Optional[str] = None
    price: float


class Item(ItemCreate):
    id: int


_store: dict = {}    # { item_id: Item }
_next_id: int = 1


@app.post("/items")
def create_item(item: ItemCreate):
    # Store the item with an auto-assigned id and return it.
    # The response status code must be 201 Created.
    raise HTTPException(status_code=501, detail="not implemented")


@app.get("/items")
def list_items():
    # Return a list of all items.
    raise HTTPException(status_code=501, detail="not implemented")


@app.get("/items/{item_id}")
def get_item(item_id: int):
    # Return the item, or 404 if item_id does not exist.
    raise HTTPException(status_code=501, detail="not implemented")


@app.put("/items/{item_id}")
def update_item(item_id: int, item: ItemCreate):
    # Replace the stored item and return the updated version, or 404.
    raise HTTPException(status_code=501, detail="not implemented")


@app.delete("/items/{item_id}")
def delete_item(item_id: int):
    # Delete the item and return 204 No Content, or 404 if not found.
    raise HTTPException(status_code=501, detail="not implemented")
PYEOF

# ── tests/test_api.py harness ───────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_api.py" << 'PYEOF'
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_create_returns_201():
    r = client.post("/items", json={"name": "Wrench", "price": 12.99})
    assert r.status_code == 201, f"POST /items must return 201, got {r.status_code}"
    data = r.json()
    assert "id" in data
    assert data["name"] == "Wrench"


def test_create_assigns_unique_ids():
    r1 = client.post("/items", json={"name": "A", "price": 1.0})
    r2 = client.post("/items", json={"name": "B", "price": 2.0})
    assert r1.status_code == 201
    assert r2.status_code == 201
    assert r1.json()["id"] != r2.json()["id"]


def test_list_returns_200():
    r = client.get("/items")
    assert r.status_code == 200
    assert isinstance(r.json(), list)


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


def test_update_item():
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
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement the five endpoint bodies in main.py so the"
echo "                 pytest harness in tests/test_api.py passes (9 tests)."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install fastapi pytest httpx"
echo
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-10-backend-engineering/challenges/01-build-a-rest-api/verify.sh"
