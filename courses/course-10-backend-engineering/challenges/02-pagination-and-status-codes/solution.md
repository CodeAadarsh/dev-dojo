# Solution — Pagination & Status Codes

Three independent fixes. Each maps to a labelled `BUG-*` comment in the skeleton.

```python
from fastapi import FastAPI, HTTPException, Query
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


@app.post("/items", status_code=201)           # FIX BUG-1: 201 Created
def create_item(item: ItemCreate) -> Item:
    global _next_id
    new_item = Item(id=_next_id, **item.model_dump())
    _store[_next_id] = new_item
    _next_id += 1
    return new_item


@app.get("/items")
def list_items(                                # FIX BUG-3: limit/offset pagination
    limit: int = Query(default=100, ge=0),
    offset: int = Query(default=0, ge=0),
) -> List[Item]:
    items = list(_store.values())
    return items[offset : offset + limit]


@app.get("/items/{item_id}")
def get_item(item_id: int) -> Item:            # FIX BUG-2: 404 instead of KeyError
    if item_id not in _store:
        raise HTTPException(status_code=404, detail="Item not found")
    return _store[item_id]


@app.put("/items/{item_id}")
def update_item(item_id: int, item: ItemCreate) -> Item:  # FIX BUG-2
    if item_id not in _store:
        raise HTTPException(status_code=404, detail="Item not found")
    updated = Item(id=item_id, **item.model_dump())
    _store[item_id] = updated
    return updated


@app.delete("/items/{item_id}", status_code=204)
def delete_item(item_id: int):                 # FIX BUG-2
    if item_id not in _store:
        raise HTTPException(status_code=404, detail="Item not found")
    del _store[item_id]
```

## Why each fix works

### BUG-1 — `status_code=201` on `@app.post`

FastAPI defaults every route to 200. The override is in the decorator, not in the handler body — that's by design, so the framework knows the declared status at route-registration time (used for OpenAPI schema generation too).

### BUG-2 — `if item_id not in _store: raise HTTPException(status_code=404)`

An unguarded `_store[item_id]` raises Python's `KeyError`. FastAPI catches it as an unhandled exception and returns 500 — which leaks the internal representation to the caller. The guard converts it to a semantic 404, which is both correct and opaque about internals.

### BUG-3 — `Query(default=100, ge=0)` parameters on `list_items`

`Query` is the FastAPI type that binds a function parameter to a query-string value. Declaring `limit: int = Query(default=100, ge=0)` means: accept `?limit=N`, default to 100, reject negative values with a 422. The slice `items[offset : offset + limit]` is idiomatic Python — empty if offset is past the end. This is cursor-free offset pagination: simple, correct for small datasets, and the standard pattern before you need keyset pagination at scale.

The 422 on invalid body (BUG for `test_post_invalid_body_returns_422`) requires **no code change** — Pydantic raises `RequestValidationError` before your handler runs whenever a required field is absent, and FastAPI maps that to 422 automatically. You get it for free by declaring `price: float` as non-optional in `ItemCreate`.

## Apply and verify

```bash
cd ~/.kube-dojo-work/02-pagination-and-status-codes
# replace main.py with the solution above, then:
.venv/bin/pytest tests/ -v
bash courses/course-10-backend-engineering/challenges/02-pagination-and-status-codes/verify.sh
```
