#!/usr/bin/env bash
# Plants the "CRUD API with Status Codes" starter project.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/01-crud-api"
mkdir -p "$WORK/tests"

# ── main.py skeleton ─────────────────────────────────────────────────────────
cat > "$WORK/main.py" << 'PYEOF'
# main.py — items CRUD skeleton
# Implement the five endpoint bodies.
# The Pydantic models and in-memory store are ready.
# Only the logic inside each function is stubbed with a 501 placeholder.
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


@app.post("/items")
def create_item(item: ItemCreate):
    # Assign an id, persist the item, return it.
    # Response status code must be 201 Created.
    raise HTTPException(status_code=501, detail="not implemented")


@app.get("/items")
def list_items():
    # Return all items as a list.
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

# ── tests/__init__.py ─────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

# ── tests/test_sample.py — visible warm-up test ──────────────────────────────
cat > "$WORK/tests/test_sample.py" << 'PYEOF'
# Visible warm-up test — make this pass first, then run verify.sh.
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_app_starts():
    """The app must import and respond to any request (even 501)."""
    r = client.get("/items")
    # Once implemented, this should be 200. Right now 501 is fine to confirm
    # the app loads without import errors.
    assert r.status_code in (200, 501), (
        f"Unexpected status {r.status_code} — check for import errors in main.py"
    )
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement the five endpoint bodies in main.py"
echo "                 so the hidden pytest harness passes."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install fastapi 'uvicorn[standard]' httpx pytest pydantic"
echo
echo "Warm-up test   : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag  : bash courses/course-15-fastapi-production/challenges/01-crud-api/verify.sh"
