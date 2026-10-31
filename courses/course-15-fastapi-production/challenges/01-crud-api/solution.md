# Solution — CRUD API with Status Codes

Complete `main.py` implementation below.

```python
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
```

## Why each piece is required

**`status_code=201` on `@app.post`.**
FastAPI defaults every route to 200. The override is in the decorator, not the return value — the framework sets the status code before serialising the response body, so `return new_item` on a `status_code=201` route atomically produces 201 + JSON body.

**`status_code=204` on `@app.delete` + no return.**
204 means "success with no body." FastAPI respects this when the declared status is 204 and the function returns `None` (implicit). Returning `{}` produces a malformed 204 — the spec says no body, and some proxies will strip it anyway. Return nothing.

**`HTTPException(status_code=404)` on every missing-key path.**
An unhandled `KeyError` from `_store[item_id]` returns a 500. 500 leaks internals, breaks client error handling, and fails code review. The guard `if item_id not in _store` before any access is the pattern — explicit, covers every path, testable.

**`item.model_dump()`** is Pydantic v2's method (v1 was `.dict()`). The `**` unpack into `Item(id=..., **body.model_dump())` constructs a full Pydantic model from validated, coerced values — not from raw JSON strings.

**`global _next_id`** is required in Python when you reassign a module-level name from inside a function. If you omit it, Python treats `_next_id` as a local variable in `create_item`, and `_next_id += 1` raises `UnboundLocalError`. Reading a module-level variable (without reassigning) doesn't require `global`.

## Apply and verify

```bash
cd ~/.kube-dojo-work/01-crud-api
# Replace main.py with the solution above, then:
.venv/bin/pytest tests/test_sample.py -v
bash courses/course-15-fastapi-production/challenges/01-crud-api/verify.sh
```
