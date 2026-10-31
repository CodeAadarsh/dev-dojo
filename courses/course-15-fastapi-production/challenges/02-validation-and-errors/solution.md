# Solution — Validation and Error Envelopes

Complete `main.py` with constraints and custom exception handlers.

```python
from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException
from pydantic import BaseModel, Field
from typing import Optional, List

app = FastAPI()


@app.exception_handler(RequestValidationError)
async def validation_exception_handler(
    request: Request,
    exc: RequestValidationError,
) -> JSONResponse:
    details = [
        {
            "field": ".".join(str(loc) for loc in err["loc"]),
            "message": err["msg"],
        }
        for err in exc.errors()
    ]
    return JSONResponse(
        status_code=422,
        content={"status": 422, "error": "Unprocessable Entity", "details": details},
    )


@app.exception_handler(StarletteHTTPException)
async def starlette_http_exception_handler(
    request: Request,
    exc: StarletteHTTPException,
) -> JSONResponse:
    if exc.status_code == 404:
        return JSONResponse(
            status_code=404,
            content={
                "status": 404,
                "error": "Not Found",
                "message": f"{request.url.path} not found",
            },
        )
    return JSONResponse(
        status_code=exc.status_code,
        content={"status": exc.status_code, "error": str(exc.detail)},
    )


class ItemCreate(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    description: Optional[str] = None
    price: float = Field(gt=0)


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

**`Field(min_length=1, max_length=120)` on `name`.**
`min_length=1` rejects empty strings. Without it, `""` passes Pydantic's `str` type check and reaches the handler. `max_length=120` prevents unbounded strings from hitting the database layer.

**`Field(gt=0)` on `price`.**
`gt` = greater-than (strictly). `ge=0` would allow 0.0 which is semantically wrong for a price. `gt=0` is exact: any non-positive price is rejected at the Pydantic layer.

**`RequestValidationError` handler.**
FastAPI wraps Pydantic's `ValidationError` in a `RequestValidationError` before it leaves the framework. Registering on `RequestValidationError` (from `fastapi.exceptions`) intercepts these before the default 422 handler runs. The `exc.errors()` method returns the same list that Pydantic produces — you reshape it to the envelope your API promises.

**`StarletteHTTPException` handler (not just `HTTPException`).**
`fastapi.HTTPException` is raised from *inside* your route functions. `starlette.exceptions.HTTPException` is also raised by Starlette's routing layer when *no route matches* a path. If you only handle the first, a request to `/items/does-not-exist-route` (wrong path entirely) still returns HTML. Handling `StarletteHTTPException` catches both cases.

**Register handlers before routes.**
FastAPI processes handlers in registration order. Registering handlers after routes is technically fine — exception handlers are resolved by type, not by order — but putting them at the top of the file makes the contract obvious.

## Apply and verify

```bash
cd ~/.kube-dojo-work/02-validation-and-errors
# Replace main.py with the solution above, then:
.venv/bin/pytest tests/test_sample.py -v
bash courses/course-15-fastapi-production/challenges/02-validation-and-errors/verify.sh
```
