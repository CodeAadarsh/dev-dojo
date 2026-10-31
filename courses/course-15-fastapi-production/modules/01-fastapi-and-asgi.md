# FastAPI & ASGI Fundamentals

> **Module 01 · Course 15** — FastAPI is not magic. It is a thin layer over Starlette's ASGI implementation and Pydantic's type system. Once you understand what each layer actually does, you stop fighting the framework and start using it as leverage. This module builds that mental model from the protocol up.

You already write HTTP services. The goal here is precision: knowing *why* `async def` matters, *when* it doesn't, and what Pydantic v2 buys you over raw `dict` parsing.

---

## The ASGI Model vs WSGI

WSGI (the Flask / Django classic) is a synchronous callable interface:

```
request → app(environ, start_response) → list[bytes]
```

One request, one thread, one response. The web server (gunicorn, uWSGI) runs a pool of OS threads or processes, and each one handles a request to completion. I/O blocks the thread. Concurrency = more threads.

ASGI is its async successor:

```
request → await app(scope, receive, send)
```

`scope` is the connection metadata (method, path, headers). `receive` is a coroutine that yields body chunks as they arrive. `send` is a coroutine that pushes response chunks back. The key difference: the event loop never blocks. While `await db.fetch()` is parked waiting for the database, the event loop runs other coroutines — potentially thousands of them on a single OS thread.

```
┌──────────── uvicorn process ─────────────────────────────────────────────┐
│                                                                           │
│   event loop                                                              │
│   ┌────────┐   ┌────────┐   ┌────────┐   ┌────────┐                     │
│   │req A   │   │req B   │   │req C   │   │req D   │   ...               │
│   │await db│   │await db│   │running │   │await db│                     │
│   └────────┘   └────────┘   └────────┘   └────────┘                     │
│       ↑ parked while I/O is in-flight; loop runs req C                   │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
```

**FastAPI sits on top of Starlette**, which handles ASGI routing, middleware, and request/response objects. FastAPI adds:
- Declarative dependency injection
- Automatic OpenAPI schema generation from type hints
- Pydantic-backed request validation and response serialization

Uvicorn is the ASGI server (think: gunicorn for WSGI). It owns the socket, speaks HTTP/1.1 or HTTP/2, and calls your ASGI `app`.

---

## `async def` vs `def` — the Threadpool Trap

FastAPI handles both:

```python
@app.get("/fast")
async def fast_handler():
    result = await async_db_query()   # correct: yields control to event loop
    return result

@app.get("/slow")
def sync_handler():
    result = sync_db_query()           # FastAPI runs this in a threadpool
    return result
```

**`async def` endpoint**: runs directly in the event loop. Any `await`-able I/O suspends and releases the loop.

**`def` endpoint**: FastAPI runs it in an `anyio` threadpool to avoid blocking the loop. This is the right choice for CPU-bound work or libraries that are not async-native (e.g., psycopg2, boto3 sync client).

### The trap: `def` that does async work incorrectly

```python
# WRONG — blocks the event loop for every request
@app.get("/block")
async def blocking():
    import time
    time.sleep(2)          # synchronous sleep holds the event loop hostage
    return {"ok": True}
```

Under load this serializes all requests. One `time.sleep(2)` call with 10 concurrent requests takes 20 seconds total instead of 2.

```python
# CORRECT — release the event loop
@app.get("/nonblock")
async def non_blocking():
    import asyncio
    await asyncio.sleep(2)    # yields; loop serves other requests while parked
    return {"ok": True}
```

The diagnostic rule: **in an `async def` endpoint, every I/O call that does not `await` is a bug**. Common offenders: `requests.get()`, `open()`, synchronous ORM queries (SQLAlchemy 1.x), `subprocess.run()` without `asyncio.create_subprocess_*`.

When you genuinely need a sync library inside an async endpoint, reach for `anyio.to_thread.run_sync`:

```python
import anyio

@app.get("/compat")
async def compat():
    result = await anyio.to_thread.run_sync(sync_heavy_function)
    return result
```

---

## Path, Query, and Body Parameters

FastAPI infers parameter origin from where the name appears:

```python
from fastapi import FastAPI, Query, Path
from pydantic import BaseModel

app = FastAPI()


@app.get("/items/{item_id}")
async def get_item(
    item_id: int,                           # path param — coerced from string
    q: str | None = None,                   # query param — optional
    page: int = Query(default=1, ge=1),     # query with constraint
):
    return {"item_id": item_id, "q": q, "page": page}
```

**Path parameters** are matched by name against `{item_id}` in the route template. FastAPI coerces and validates the type — `GET /items/abc` returns a 422 automatically.

**Query parameters** are anything in the function signature that is not in the path and not a `BaseModel` subclass. Annotate with `Query(...)` to add constraints (min/max length, regex, numeric bounds) that are reflected in the OpenAPI schema.

**Body parameters** — declare a `BaseModel` subclass as the argument type:

```python
class ItemCreate(BaseModel):
    name: str
    price: float
    tags: list[str] = []


@app.post("/items", status_code=201)
async def create_item(item: ItemCreate) -> Item:
    ...
```

FastAPI reads the JSON body, passes it to Pydantic for validation, and injects the resulting model instance. Malformed JSON or a missing required field returns a 422 Unprocessable Entity with a machine-readable error list — for free, no `try/except` needed.

**Multiple body params**: wrap them each in `BaseModel`, or use `Body(embed=True)` to nest under a key.

```python
@app.put("/items/{item_id}")
async def update_item(
    item_id: int,
    item: ItemCreate,          # body — first BaseModel
    user: UserContext,         # body — second BaseModel; FastAPI merges them
):
    ...
```

---

## Pydantic v2 Request and Response Models

Pydantic v2 is a complete rewrite in Rust. The API surface is mostly compatible with v1, but the internals are faster and the validation behaviour is stricter. Key things to know for FastAPI:

**Request model** — what the client sends in:

```python
from pydantic import BaseModel, Field


class ProductCreate(BaseModel):
    name: str
    price: float = Field(gt=0, description="must be positive")
    category: str
    in_stock: bool = True
```

**Response model** — what the service sends back. Declare it on the decorator:

```python
class Product(ProductCreate):
    id: int
    created_at: datetime


@app.post("/products", status_code=201, response_model=Product)
async def create_product(product: ProductCreate) -> Product:
    ...
```

`response_model` on the decorator does two things:
1. FastAPI serializes the return value through `Product`, stripping any extra fields the ORM or internal logic added.
2. It drives the OpenAPI schema for the `201` response.

**Prefer type annotations on the return type** for modern FastAPI (0.95+), but `response_model=` is still needed when you want to suppress fields selectively:

```python
@app.get("/products/{pid}", response_model=Product, response_model_exclude={"internal_notes"})
async def get_product(pid: int) -> Product:
    ...
```

`response_model_exclude` takes a set of field names. Use `response_model_include` when you want to whitelist instead. Both only work on the outermost model — they don't recurse into nested models.

---

## Automatic OpenAPI / Swagger

FastAPI builds an OpenAPI 3.1 spec from your route signatures at startup. Browse it at:

```
http://localhost:8000/docs       # Swagger UI (interactive)
http://localhost:8000/redoc      # ReDoc (readable)
http://localhost:8000/openapi.json
```

The spec is entirely driven by your Python types. The more specific your annotations, the richer the docs:

```python
from fastapi import FastAPI
from pydantic import BaseModel, Field

app = FastAPI(
    title="Inventory Service",
    version="1.0.0",
    description="Internal product catalog — no public SLA.",
)


class ProductCreate(BaseModel):
    name: str = Field(min_length=1, max_length=100, examples=["HDMI Cable"])
    price: float = Field(gt=0, examples=[9.99])
```

`examples` on `Field(...)` feeds the "Try it out" form in Swagger UI. Invest 5 minutes here when building an API your team will consume — it saves hours of Slack questions.

---

## Status Codes — Getting Them Right

FastAPI defaults to 200 for `GET` and 200 for everything else — wrong for `POST`. Declare the correct code on the decorator:

| Scenario | Code | Declaration |
|----------|------|-------------|
| Resource created | 201 Created | `@app.post("/...", status_code=201)` |
| No body to return | 204 No Content | `@app.delete("/...", status_code=204)` |
| Async accepted, processing later | 202 Accepted | `@app.post("/...", status_code=202)` |
| Client error (missing resource) | 404 Not Found | `raise HTTPException(status_code=404)` |
| Client sends invalid data | 422 Unprocessable Entity | raised automatically by Pydantic |
| Auth missing | 401 Unauthorized | `raise HTTPException(status_code=401)` |
| Auth present but insufficient | 403 Forbidden | `raise HTTPException(status_code=403)` |

Return a 204 with an empty body — FastAPI strips the body automatically when `status_code=204`:

```python
from fastapi import Response


@app.delete("/items/{item_id}", status_code=204)
async def delete_item(item_id: int) -> Response:
    if item_id not in _store:
        raise HTTPException(status_code=404)
    del _store[item_id]
    return Response(status_code=204)
```

**`HTTPException` detail is exposed in the response.** Don't put internal state (SQL, stack traces, internal IDs) in `detail`. Stick to human-readable error descriptions the caller can act on.

---

## Debugging FastAPI & ASGI Fundamentals

Most "my endpoint is broken" incidents in FastAPI fall into three buckets:

| Symptom | Cause | Fix |
|---------|-------|-----|
| `422 Unprocessable Entity` on a valid-looking request | Pydantic model mismatch — the JSON key names, types, or nesting don't match the model | Read the 422 body; it lists every failing field with `loc` (location path) and `msg` (human reason). Fix the model or the test payload. |
| Endpoint is slow / high latency under concurrent load | Blocking call inside `async def` — `time.sleep`, `requests.get`, synchronous DB driver | Move to `await asyncio.sleep` / `httpx.AsyncClient` / async ORM, or convert to a plain `def` endpoint (threadpool) |
| Response includes fields you expected to hide | `response_model_exclude` applied to wrong layer, or `response_model` not set at all | Confirm `response_model=` is on the decorator, not just the return type annotation; add `response_model_exclude={"field_name"}` |
| `POST /items` returns 200 instead of 201 | Default status code on `@app.post` | Add `status_code=201` to the decorator |
| `DELETE` returns a body even though you return 204 | Returning a dict/model with `status_code=204` | Return `Response(status_code=204)` — an empty `Response` object, not a model |
| Swagger UI shows `string` type for an `int` query param | Missing `Query(...)` annotation, or annotated as `str` | Annotate with `q: int = Query(...)` |

### Diagnosing a 422 — exactly where Pydantic rejected your request

```python
# In development, enable detailed validation errors:
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

@app.exception_handler(RequestValidationError)
async def validation_handler(request, exc):
    return JSONResponse(
        status_code=422,
        content={"detail": exc.errors(), "body": exc.body},  # see the raw body
    )
```

The `exc.errors()` list has one entry per failing field. `loc` is a tuple like `("body", "price")` — the path into the JSON where validation failed.

### The threadpool trap in production

The symptom is subtle: in load tests, `async def` endpoints with sync I/O show latency that scales *with* concurrency, not independently. Diagnose with a profiler or a simple timing test:

```bash
# two concurrent requests — if async, both finish in ~2s total; if blocked, ~4s
hey -n 2 -c 2 http://localhost:8000/slow-endpoint
```

`hey` (or `wrk`, `vegeta`) makes this visible. Under correct async, 2 concurrent 2-second requests complete in ~2 seconds wall time. Under accidental blocking, they serialise to ~4 seconds.

> **War story.** At SAP I onboarded a service that called `requests.get()` inside an `async def` route to hit an internal observability endpoint. In staging it was invisible — latency under 20 ms. Under the 100GB+/day production ingestion load, the event loop was blocked by thousands of those sync HTTP calls. P99 latency climbed from 50 ms to 4 seconds over 6 hours until the loop starved and health checks failed. The fix was one line: swap `requests` for `httpx.AsyncClient` with `await client.get(...)`. The lesson: **every `import requests` inside an `async def` function is a latency time-bomb under load.** Grep for it the same way you grep for `TODO`.

---

## Checkpoint

You're ready for the challenge when you can, without looking anything up:

1. Describe the ASGI `(scope, receive, send)` triple and what each coroutine does.
2. Explain why a `time.sleep(2)` inside `async def` is worse than inside `def`, and how to fix each.
3. Identify, from a function signature alone, whether a parameter is path, query, or body.
4. Set the correct HTTP status code for a create endpoint (201), a delete endpoint (204), and an authentication failure (401).
5. Find a 422 error's exact failing field using the error response's `loc` list.
6. Name two real async HTTP clients that replace `requests` in an async context.
7. Explain what `response_model` on the decorator does that a return type annotation alone does not.

➡ Next up: the **FastAPI First Principles** challenge — you'll repair a broken product catalog that has wrong status codes, raw-dict returns, and broken query parameters.
