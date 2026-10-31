# Dependency Injection & App Structure

> **Module 03 · Course 15** — Dependency injection in FastAPI is not a design pattern you opt into for large projects. It is the mechanism that makes test isolation, configuration management, and per-request resource lifetimes work correctly. Get it wrong and your tests share state, your settings are hardcoded, and your DB connections leak.

---

## `Depends()` — the Basics

A FastAPI dependency is any callable. FastAPI resolves it before calling your route function and injects the result:

```python
from fastapi import Depends, FastAPI

app = FastAPI()


def get_current_user_id() -> int:
    # In a real app: parse JWT from the Authorization header
    return 42


@app.get("/profile")
async def profile(user_id: int = Depends(get_current_user_id)):
    return {"user_id": user_id}
```

`Depends(get_current_user_id)` tells FastAPI: "call `get_current_user_id()` and pass the return value as `user_id`." The dependency itself can declare parameters — FastAPI resolves them recursively.

**You can inject request context too:**

```python
from fastapi import Request


def get_request_id(request: Request) -> str:
    return request.headers.get("X-Request-ID", "none")


@app.get("/debug")
async def debug(req_id: str = Depends(get_request_id)):
    return {"request_id": req_id}
```

Dependencies can be `async def` or plain `def`. FastAPI handles both.

---

## Sub-dependencies

Dependencies can depend on other dependencies:

```python
from fastapi import Depends
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials

bearer = HTTPBearer()


def get_token(credentials: HTTPAuthorizationCredentials = Depends(bearer)) -> str:
    return credentials.credentials


def get_current_user(token: str = Depends(get_token)) -> dict:
    # Decode the token — raises HTTPException(401) on invalid
    return decode_jwt(token)


def require_admin(user: dict = Depends(get_current_user)) -> dict:
    if user.get("role") != "admin":
        raise HTTPException(status_code=403, detail="admin required")
    return user


@app.delete("/users/{uid}")
async def delete_user(uid: int, _: dict = Depends(require_admin)):
    ...
```

FastAPI builds a dependency graph and resolves each node once per request. If two endpoints both use `get_current_user`, it is called once and the result is cached for the duration of that request — not globally, per-request.

**Dependency caching is scoped to a single request.** The same dependency called 10 times in one request runs once. If you need a new instance per call, add `use_cache=False`:

```python
Depends(get_db, use_cache=False)
```

---

## Yield Dependencies — Setup / Teardown

This is the pattern that replaces `try/finally` connection management:

```python
from typing import Generator
from sqlalchemy.orm import Session


def get_db() -> Generator[Session, None, None]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


@app.get("/users/{uid}")
async def get_user(uid: int, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.id == uid).first()
    if not user:
        raise HTTPException(status_code=404)
    return user
```

FastAPI runs `db = SessionLocal()` before the route function, yields `db` into the route, then runs `db.close()` after the response is sent — even if the route raises an exception. The `finally` block runs unconditionally.

**Yield dependencies and exception handling:**

```python
def get_db():
    db = SessionLocal()
    try:
        yield db
        db.commit()           # only runs if route didn't raise
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()            # always runs
```

This pattern gives you per-request transactions: commit on success, rollback on exception. Each request gets a fresh DB session — no cross-request state.

**Nested yield dependencies work too:**

```python
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def get_user_repo(db: Session = Depends(get_db)) -> UserRepository:
    return UserRepository(db)


@app.get("/users/{uid}")
async def get_user(uid: int, repo: UserRepository = Depends(get_user_repo)):
    return repo.get(uid)
```

FastAPI tears down the entire dependency graph in reverse order after the response is sent.

---

## `APIRouter` — Organising Routes

Registering every route directly on `app` doesn't scale past ~15 endpoints. `APIRouter` lets you split routes across files and compose them:

```python
# routers/users.py
from fastapi import APIRouter, Depends

router = APIRouter(prefix="/users", tags=["users"])


@router.get("/{uid}")
async def get_user(uid: int, db=Depends(get_db)):
    ...


@router.post("/", status_code=201)
async def create_user(user: UserCreate, db=Depends(get_db)):
    ...
```

```python
# main.py
from fastapi import FastAPI
from routers import users, products, auth

app = FastAPI()

app.include_router(users.router)
app.include_router(products.router)
app.include_router(auth.router, prefix="/auth")
```

`prefix` on the `include_router` call overrides the `APIRouter`'s own prefix — useful when you want the router to be prefix-agnostic and let the mounting point decide.

`tags` group routes in the Swagger UI. If omitted, all routes appear in `default`.

**Override a dependency for a whole router:**

```python
app.include_router(
    products.router,
    dependencies=[Depends(require_admin)],   # every route in products requires admin
)
```

---

## Settings via `pydantic-settings`

Hard-coded config in the module body is the most common cause of "works on my machine":

```python
# Anti-pattern
DATABASE_URL = "postgresql://localhost/mydb"    # hardcoded
```

`pydantic-settings` reads environment variables (and `.env` files) into a typed Pydantic model:

```python
# config.py
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    database_url: str
    jwt_secret: str
    app_name: str = "My API"
    debug: bool = False
    max_connections: int = 10


settings = Settings()   # reads from env; raises ValidationError if DATABASE_URL missing
```

`Settings()` is instantiated at module import time. If `DATABASE_URL` is missing from the environment, the app fails to start with a clear error — not silently at the first DB call. This is the correct failure mode.

**Use `lru_cache` to make the settings a singleton for DI:**

```python
from functools import lru_cache


@lru_cache
def get_settings() -> Settings:
    return Settings()


@app.get("/info")
async def info(settings: Settings = Depends(get_settings)):
    return {"app": settings.app_name, "debug": settings.debug}
```

`@lru_cache` ensures `Settings()` is constructed once. In tests, override the dependency:

```python
def override_settings():
    return Settings(database_url="sqlite:///:memory:", jwt_secret="test-secret")

app.dependency_overrides[get_settings] = override_settings
```

---

## Lifespan Events

`startup` / `shutdown` events are where you initialise connection pools, load ML models, or warm caches — and tear them down cleanly:

```python
# Modern style (FastAPI 0.93+): lifespan context manager
from contextlib import asynccontextmanager
from fastapi import FastAPI


@asynccontextmanager
async def lifespan(app: FastAPI):
    # startup
    await db_pool.connect()
    await cache.connect()
    print("startup complete")
    yield
    # shutdown (runs on SIGTERM / process exit)
    await db_pool.disconnect()
    await cache.disconnect()
    print("shutdown complete")


app = FastAPI(lifespan=lifespan)
```

The old `@app.on_event("startup")` / `@app.on_event("shutdown")` decorators are deprecated. Use `lifespan`.

**Why lifespan over module-level initialization:**
- Module-level `await` requires a running event loop — you can't `await` at import time.
- Lifespan runs *inside* the event loop, so async init (connecting to Redis, opening a thread pool) works correctly.
- Teardown is guaranteed even if startup raises partway through.

---

## Project Layout

A layout that scales from 5 to 50 routes without circular imports:

```
src/
├── main.py            # app factory, includes routers, wires lifespan
├── config.py          # Settings(BaseSettings), get_settings()
├── dependencies.py    # get_db(), get_current_user(), shared deps
├── models/
│   ├── __init__.py
│   └── user.py        # SQLAlchemy ORM models
├── schemas/
│   ├── __init__.py
│   └── user.py        # Pydantic request/response schemas
└── routers/
    ├── __init__.py
    ├── users.py
    ├── products.py
    └── auth.py
```

**The circular import trap**: `routers/users.py` imports `dependencies.get_db`, `dependencies.py` imports `models/user.py`, `models/user.py` imports `config.settings`. If any of these import from `main.py` (to get `app`), you have a cycle. **`main.py` should import everything else; nothing should import `main.py`.**

This means `APIRouter` instances live in `routers/`, not in `main.py`. `main.py` only calls `app.include_router(...)`.

---

## Debugging Dependency Injection & App Structure

| Symptom | Cause | Fix |
|---------|-------|-----|
| Test changes to `app.dependency_overrides` have no effect | The route uses the dependency's return value directly (not via `Depends`) — or the override key doesn't match the exact function object | Confirm the route signature has `= Depends(get_db)` with the imported `get_db`; the override key must be the same object (`from main import get_db`, not a re-imported copy) |
| Request-scoped state persists between tests | Yield dependency creates module-level state instead of per-call state | Move the store/session creation inside the yield body, not at the module level |
| `ImportError: cannot import name 'app' from 'routers.users'` | `routers/users.py` imported `app` from `main.py` to register routes | Move to `APIRouter`; routers should never import `app` |
| `MissingGreenlet` / `RuntimeError: no running event loop` in lifespan | Blocking call inside `async def lifespan` (e.g., synchronous DB init) | Use async drivers; or `await anyio.to_thread.run_sync(sync_init_fn)` |
| Dependency is called multiple times per request unexpectedly | `use_cache=False` set somewhere in the chain | Remove `use_cache=False` unless you explicitly want fresh instances |
| `ValidationError` at startup: missing env var | `Settings()` instantiated at module import time; env var not set in the test process | Either provide the env var in your test runner or set `_env_file=None` and pass defaults: `Settings(_env_file=None, database_url="sqlite:///:memory:")` |

### Confirming an override is actually wiring

A common mistake: the developer adds the override but imports `get_db` from the wrong module (a copy, not the same function object):

```python
# tests/conftest.py

# WRONG — different function object; override silently does nothing
from app.database import get_db as _get_db
from main import app

def fake_db():
    yield {"test": True}

app.dependency_overrides[_get_db] = fake_db


# CORRECT — same function object FastAPI stored in the route
from main import app, get_db

app.dependency_overrides[get_db] = fake_db
```

The override map key must be *identity-equal* to the callable FastAPI registered. If `main.py` re-exports `get_db` via `from dependencies import get_db`, import from `main` in your test — not from `dependencies`. Or, better, expose it directly and import once from its canonical location.

### Request-scoped state leak — what it looks like in tests

```python
def test_isolation_failure():
    client = TestClient(app)
    client.post("/tasks", json={"title": "leaked"})

    client2 = TestClient(app)                  # fresh client, but global store still full
    r = client2.get("/tasks")
    assert len(r.json()) == 0                  # FAILS if routes use global _store
```

If this test fails, your routes are using module-level state instead of the injected dependency. The fix is to move the store into the yield body and confirm routes receive it via `Depends(get_db)`.

> **War story.** A background ingestion pipeline I inherited ran 12 pytest tests that all passed individually but failed in a full run with inconsistent counts. The root cause: a `db_connection` object was opened at module import time (not in a yield dep), then recycled across tests. Tests 7–9 saw partial data from tests 1–6 because the "connection" was actually a shared in-memory cache. Moving the connection into a yield dependency and adding `app.dependency_overrides[get_db] = get_test_db` in the pytest `conftest.py` fixed it in one commit. The tell-tale sign was always: tests pass solo, fail in a suite — look for module-level mutable state first.

---

## Checkpoint

You're ready for the challenge when you can, without looking anything up:

1. Write a yield dependency that opens a resource before `yield` and closes it after, in both success and exception paths.
2. Explain why `app.dependency_overrides[get_db]` has no effect if the route doesn't use `Depends(get_db)`.
3. Set up `pydantic-settings` so the app fails at startup (not at first use) when a required env var is missing.
4. Describe what `@lru_cache` on `get_settings()` does and why it is needed.
5. Explain why routes in `routers/users.py` must use `APIRouter`, not `app.get(...)`, and what happens if they import `app` from `main.py`.
6. Structure a lifespan that initialises a DB pool and a Redis cache in startup and tears them down in shutdown.
7. Diagnose a test isolation failure — state leaking between tests — and trace it to the correct fix.

➡ Next up: the **Dependency Injection** challenge — you'll refactor a leaky, all-in-`main.py` task API into one that passes DI isolation tests with `app.dependency_overrides`.
