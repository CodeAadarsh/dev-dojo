#!/usr/bin/env bash
# Plants the "Validation and Error Envelopes" starter project.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/02-validation-and-errors"
mkdir -p "$WORK/tests"

# ── main.py skeleton ──────────────────────────────────────────────────────────
cat > "$WORK/main.py" << 'PYEOF'
# main.py — validation and error handling challenge
#
# The CRUD endpoints are already implemented.
# Your tasks:
#   1. Add field constraints to ItemCreate (name: non-empty, max 120; price: > 0).
#   2. Register a RequestValidationError handler returning:
#        {"status": 422, "error": "Unprocessable Entity", "details": [...]}
#   3. Register a StarletteHTTPException handler for 404 returning:
#        {"status": 404, "error": "Not Found", "message": "<path> not found"}
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Optional, List

app = FastAPI()


class ItemCreate(BaseModel):
    # TODO: add Field constraints — name non-empty/max 120, price > 0
    name: str
    description: Optional[str] = None
    price: float


class Item(ItemCreate):
    id: int


_store: dict = {}
_next_id: int = 1


# TODO: register RequestValidationError handler here
# from fastapi.exceptions import RequestValidationError
# from fastapi import Request
# from fastapi.responses import JSONResponse


# TODO: register StarletteHTTPException handler here (for 404)
# from starlette.exceptions import HTTPException as StarletteHTTPException


@app.post("/items", status_code=201)
def create_item(item: ItemCreate) -> Item:
    global _next_id
    new_item = Item(id=_next_id, **item.model_dump())
    _store[_next_id] = new_item
    _next_id += 1
    return new_item


@app.get("/items")
def list_items() -> List[Item]:
    return list(_store.values())


@app.get("/items/{item_id}")
def get_item(item_id: int) -> Item:
    if item_id not in _store:
        raise HTTPException(status_code=404, detail="Item not found")
    return _store[item_id]


@app.put("/items/{item_id}")
def update_item(item_id: int, item: ItemCreate) -> Item:
    if item_id not in _store:
        raise HTTPException(status_code=404, detail="Item not found")
    updated = Item(id=item_id, **item.model_dump())
    _store[item_id] = updated
    return updated


@app.delete("/items/{item_id}", status_code=204)
def delete_item(item_id: int):
    if item_id not in _store:
        raise HTTPException(status_code=404, detail="Item not found")
    del _store[item_id]
PYEOF

# ── tests/__init__.py ─────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

# ── tests/test_sample.py — visible warm-up ───────────────────────────────────
cat > "$WORK/tests/test_sample.py" << 'PYEOF'
# Visible warm-up test — confirms the app imports and basic 422 fires.
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_empty_name_triggers_some_422():
    """Once you add constraints, empty name must return 422."""
    r = client.post("/items", json={"name": "", "price": 10.0})
    # Before constraints are added this will be 201 (no validation).
    # After constraints: 422.
    assert r.status_code in (201, 422), (
        f"Unexpected status {r.status_code} — check main.py for import errors"
    )


def test_valid_item_returns_201():
    r = client.post("/items", json={"name": "Hammer", "price": 9.99})
    assert r.status_code == 201
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : edit main.py"
echo "                 1. Add Field constraints to ItemCreate"
echo "                 2. Register a RequestValidationError handler"
echo "                 3. Register a StarletteHTTPException handler for 404"
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install fastapi 'uvicorn[standard]' httpx pytest pydantic"
echo
echo "Warm-up test   : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag  : bash courses/course-15-fastapi-production/challenges/02-validation-and-errors/verify.sh"
