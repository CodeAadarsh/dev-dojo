#!/usr/bin/env bash
# Plants the "Pagination & Status Codes" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/02-pagination-and-status-codes"
mkdir -p "$WORK/tests"

# ── main.py skeleton (deliberately broken) ──────────────────────────────────
cat > "$WORK/main.py" << 'PYEOF'
# main.py — items API with three classes of bugs to fix:
#   BUG-1  Wrong status codes: POST returns 200, DELETE returns 200
#   BUG-2  No 404 handling: KeyError propagates as 500 on missing IDs
#   BUG-3  No pagination: GET /items ignores limit/offset, returns everything
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


_store: dict = {}
_next_id: int = 1


@app.post("/items")                      # BUG-1: should be status_code=201
def create_item(item: ItemCreate) -> Item:
    global _next_id
    new_item = Item(id=_next_id, **item.model_dump())
    _store[_next_id] = new_item
    _next_id += 1
    return new_item


@app.get("/items")                       # BUG-3: no limit/offset parameters
def list_items() -> List[Item]:
    return list(_store.values())


@app.get("/items/{item_id}")             # BUG-2: KeyError instead of 404
def get_item(item_id: int) -> Item:
    return _store[item_id]


@app.put("/items/{item_id}")             # BUG-2: KeyError instead of 404
def update_item(item_id: int, item: ItemCreate) -> Item:
    _store[item_id] = Item(id=item_id, **item.model_dump())
    return _store[item_id]


@app.delete("/items/{item_id}", status_code=204)  # status correct, but...
def delete_item(item_id: int):           # BUG-2: KeyError instead of 404
    del _store[item_id]
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


def _make_items(n: int) -> list:
    ids = []
    for i in range(n):
        r = client.post("/items", json={"name": f"item-{i}", "price": float(i + 1)})
        ids.append(r.json()["id"])
    return ids


def test_post_returns_201():
    r = client.post("/items", json={"name": "Bolt", "price": 0.99})
    assert r.status_code == 201, f"POST /items must return 201, got {r.status_code}"


def test_post_invalid_body_returns_422():
    r = client.post("/items", json={"name": "NoPrice"})
    assert r.status_code == 422, f"missing required field must return 422, got {r.status_code}"


def test_list_default_returns_200():
    r = client.get("/items")
    assert r.status_code == 200
    assert isinstance(r.json(), list)


def test_pagination_limit():
    _make_items(5)
    r = client.get("/items?limit=3")
    assert r.status_code == 200
    items = r.json()
    assert len(items) <= 3, f"limit=3 must return at most 3 items, got {len(items)}"


def test_pagination_offset():
    _make_items(6)
    page1 = client.get("/items?limit=3&offset=0").json()
    page2 = client.get("/items?limit=3&offset=3").json()
    ids1 = {i["id"] for i in page1}
    ids2 = {i["id"] for i in page2}
    assert ids1.isdisjoint(ids2), "pages at offset=0 and offset=3 must not overlap"


def test_get_missing_returns_404():
    r = client.get("/items/999999")
    assert r.status_code == 404


def test_put_missing_returns_404():
    r = client.put("/items/999999", json={"name": "X", "price": 1.0})
    assert r.status_code == 404


def test_delete_returns_204():
    create = client.post("/items", json={"name": "Temp", "price": 1.0})
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
echo "Task           : fix the three bug classes in main.py so the harness"
echo "                 in tests/test_api.py passes (9 tests)."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install fastapi pytest httpx"
echo
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-10-backend-engineering/challenges/02-pagination-and-status-codes/verify.sh"
