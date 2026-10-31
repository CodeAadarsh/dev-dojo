#!/usr/bin/env bash
# Plants the "FastAPI First Principles" starter project into the work directory.
# Idempotent — re-running overwrites source files but does not touch .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/01-fastapi-first-principles"
mkdir -p "$WORK/tests"

# ── main.py skeleton ─────────────────────────────────────────────────────────
cat > "$WORK/main.py" << 'PYEOF'
# main.py — product catalog skeleton
# Four deliberate defects to fix:
#   1. POST /products returns 200 — should be 201.
#   2. create_product takes `body: dict` — should use a Pydantic v2 model with Field(gt=0) on price.
#   3. list_products takes `in_stock: Optional[str]` — should be Optional[bool].
#   4. get_product returns a dict with an "error" key on missing — should raise HTTPException(404).
#
# Define two Pydantic v2 models:
#   ProductCreate  name (str), category (str), price (float, gt=0), in_stock (bool = True)
#   Product        ProductCreate + id (int)
# Update all three endpoint signatures and bodies to use them.
from fastapi import FastAPI, HTTPException
from typing import Optional

app = FastAPI(title="Product Catalog")

_products: dict = {}
_next_id: int = 1


@app.post("/products", status_code=200)          # BUG: should be 201
def create_product(body: dict):                   # BUG: should use ProductCreate model
    global _next_id
    _products[_next_id] = {"id": _next_id, **body}
    _next_id += 1
    return _products[_next_id - 1]


@app.get("/products")
def list_products(in_stock: Optional[str] = None):   # BUG: should be Optional[bool]
    items = list(_products.values())
    if in_stock is not None:
        items = [i for i in items if str(i.get("in_stock", True)) == in_stock]
    return items


@app.get("/products/{product_id}")
def get_product(product_id: int):
    if product_id not in _products:
        return {"error": "not found"}             # BUG: should raise HTTPException(404)
    return _products[product_id]
PYEOF

# ── tests/test_catalog.py (visible harness) ──────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_catalog.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_create_returns_201():
    r = client.post("/products", json={"name": "Laptop", "category": "Electronics", "price": 999.0})
    assert r.status_code == 201, f"POST /products must return 201 Created, got {r.status_code}"


def test_create_assigns_id():
    r = client.post("/products", json={"name": "A", "category": "X", "price": 1.0})
    assert r.status_code == 201
    assert "id" in r.json(), "response must include 'id'"


def test_create_validates_price_positive():
    r = client.post("/products", json={"name": "Broken", "category": "X", "price": -5.0})
    assert r.status_code == 422, (
        f"negative price must fail Pydantic validation (422), got {r.status_code}. "
        "Add Field(gt=0) to the price field on ProductCreate."
    )


def test_create_requires_name():
    r = client.post("/products", json={"category": "X", "price": 1.0})
    assert r.status_code == 422, (
        f"missing required field 'name' must return 422, got {r.status_code}. "
        "Ensure create_product takes a Pydantic model, not a raw dict."
    )


def test_list_returns_list():
    r = client.get("/products")
    assert r.status_code == 200
    assert isinstance(r.json(), list), "GET /products must return a JSON array"


def test_in_stock_filter_true():
    client.post("/products", json={"name": "Available", "category": "X", "price": 1.0, "in_stock": True})
    client.post("/products", json={"name": "Unavailable", "category": "X", "price": 1.0, "in_stock": False})
    r = client.get("/products", params={"in_stock": "true"})
    assert r.status_code == 200
    data = r.json()
    assert all(p["in_stock"] for p in data), (
        "GET /products?in_stock=true must return only items where in_stock is True. "
        "Change the query param to Optional[bool] so FastAPI coerces the string."
    )


def test_get_product_returns_200():
    create = client.post("/products", json={"name": "Mug", "category": "Kitchen", "price": 9.99})
    assert create.status_code == 201
    pid = create.json()["id"]
    r = client.get(f"/products/{pid}")
    assert r.status_code == 200
    assert r.json()["name"] == "Mug"


def test_get_missing_returns_404():
    r = client.get("/products/999999")
    assert r.status_code == 404, (
        f"GET /products/999999 must return 404, got {r.status_code}. "
        "Raise HTTPException(status_code=404) instead of returning an error dict."
    )
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : fix the four defects in main.py (see comments at the top)"
echo "                 so all 8 tests in tests/test_catalog.py pass."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install fastapi 'uvicorn[standard]' httpx pytest pydantic sqlalchemy pyjwt"
echo
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-15-fastapi-production/challenges/01-fastapi-first-principles/verify.sh"
