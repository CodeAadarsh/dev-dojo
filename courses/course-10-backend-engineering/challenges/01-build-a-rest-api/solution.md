# Solution — Build a REST API

The complete `main.py` implementation. Key points below the code.

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
FastAPI defaults to 200 for every route. Overriding it in the decorator is the right place — the framework sets the status before the response body is serialised, so a `return new_item` on a `status_code=201` route gives back the 201+body atomically. Returning `JSONResponse(status_code=201, ...)` explicitly works too, but is verbose and loses the automatic model serialisation.

**`status_code=204` on `@app.delete` + returning `None`.**
204 No Content means "the action succeeded and there is nothing to render." FastAPI respects this: when the declared status is 204 and the function returns `None` (implicit or explicit), it sends an empty body. Do not `return {}` or `return {"ok": True}` — that's technically malformed for a 204.

**`HTTPException(status_code=404)` instead of letting a `KeyError` bubble.**
An unhandled Python exception from a missing dict key returns a 500. A 500 leaks information (sometimes a stack trace), breaks clients that distinguish 404 from 5xx, and is embarrassing in a code review. `if item_id not in _store: raise HTTPException(...)` is the pattern — explicit, testable, correct.

**`item.model_dump()`** is Pydantic v2's replacement for `item.dict()`. Both work if you're on an older FastAPI install; `model_dump()` is correct going forward. The `**` unpack into `Item(id=..., ...)` is idiomatic: Pydantic models accept keyword arguments, so this constructs the full model in one expression without copying field by field.

## Apply and verify

```bash
cd ~/.kube-dojo-work/01-build-a-rest-api
# replace main.py with the solution above, then:
.venv/bin/pytest tests/ -v
bash courses/course-10-backend-engineering/challenges/01-build-a-rest-api/verify.sh
```
