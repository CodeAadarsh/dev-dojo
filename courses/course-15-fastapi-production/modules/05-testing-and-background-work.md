# Testing & Background Work

> **Module 05 · Course 15** — Tests that pass locally and fail in CI, background tasks that silently swallow the exception you needed to see, and async test suites that explode with "event loop already running" — these are the three failure modes that junior developers accept as mysterious and senior developers eliminate in an afternoon. This module gives you the tools to do the latter.

---

## TestClient vs httpx.AsyncClient

FastAPI ships with `TestClient` from Starlette, which is a synchronous wrapper around
`httpx.Client` using a threading transport that runs the ASGI app in the same process. It is
simpler and covers the majority of test cases.

```python
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)

def test_create_item():
    r = client.post("/items", json={"name": "Wrench", "price": 12.99})
    assert r.status_code == 201
```

`TestClient` starts and stops a real event loop for each call, so `async def` endpoints and
dependencies work correctly. You do not need `pytest-asyncio` for sync tests against an async app.

When you need `httpx.AsyncClient` — and the cases are specific:

1. You are testing WebSocket endpoints (`TestClient.websocket_connect()` covers most of this too).
2. You need to test true concurrent requests (send two requests simultaneously to expose a race).
3. You are testing a middleware that streams responses.

```python
import pytest
import httpx
from httpx import AsyncClient

@pytest.mark.asyncio
async def test_concurrent_writes():
    async with AsyncClient(app=app, base_url="http://test") as ac:
        import asyncio
        r1, r2 = await asyncio.gather(
            ac.post("/items", json={"name": "A", "price": 1.0}),
            ac.post("/items", json={"name": "B", "price": 2.0}),
        )
    assert r1.status_code == 201
    assert r2.status_code == 201
    # both IDs must be distinct — this test would expose an ID collision race
    assert r1.json()["id"] != r2.json()["id"]
```

Default to `TestClient`. Reach for `AsyncClient` only when the test scenario genuinely requires
async behaviour that `TestClient` cannot model.

---

## pytest-asyncio

`pytest-asyncio` lets you write `async def` test functions. Install it alongside your test deps:

```bash
pip install pytest-asyncio
```

Configure it in `pyproject.toml` so you don't need the marker on every test:

```toml
[tool.pytest.ini_options]
asyncio_mode = "auto"
```

Or in `pytest.ini`:

```ini
[pytest]
asyncio_mode = auto
```

With `asyncio_mode = "auto"`, every `async def test_*` runs on a fresh event loop automatically.
Without it, you must decorate each one with `@pytest.mark.asyncio`.

### Event loop scope and shared setup

By default, `pytest-asyncio` creates a new event loop per test function. This means fixtures
with `scope="session"` or `scope="module"` that are themselves async must explicitly declare
their loop scope:

```python
import pytest

@pytest.fixture(scope="session")
async def db_engine():
    # session-scoped async fixture — event loop lives for the whole test session
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield engine
    await engine.dispose()
```

With `pytest-asyncio >= 0.21`, add `loop_scope` to the fixture:

```python
@pytest.fixture(scope="session", loop_scope="session")
async def db_engine():
    ...
```

Missing `loop_scope` on a session-scoped async fixture is the most common source of
"event loop already running" and "attached to different loop" errors.

---

## dependency_overrides for Test Doubles

`dependency_overrides` is FastAPI's official mechanism for swapping dependencies in tests. It
works at the app level: map the original dependency function to a replacement function.

### The pattern

```python
# deps.py
async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with AsyncSessionLocal() as session:
        yield session

# tests/conftest.py
import pytest
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker
from fastapi.testclient import TestClient
from main import app
from deps import get_db

TEST_DATABASE_URL = "sqlite+aiosqlite:///:memory:"

@pytest.fixture
async def db_engine():
    engine = create_async_engine(TEST_DATABASE_URL)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield engine
    await engine.dispose()

@pytest.fixture
def client(db_engine):
    TestSessionLocal = async_sessionmaker(bind=db_engine, expire_on_commit=False)

    async def override_get_db():
        async with TestSessionLocal() as session:
            try:
                yield session
                await session.commit()
            except Exception:
                await session.rollback()
                raise

    app.dependency_overrides[get_db] = override_get_db
    yield TestClient(app)
    app.dependency_overrides.clear()  # always clean up; leaked overrides contaminate other tests
```

`app.dependency_overrides.clear()` in teardown is not optional — a leaked override in one test
module will silently affect every subsequent test in the same session.

### Overriding auth dependencies

The most common production pattern is overriding `get_current_user` to avoid needing a real JWT
in every test:

```python
from deps import get_current_user
from models import User

def override_current_user():
    return User(id=1, username="test_user", email="test@example.com")

@pytest.fixture
def authed_client():
    app.dependency_overrides[get_current_user] = override_current_user
    yield TestClient(app)
    app.dependency_overrides.clear()
```

This decouples your endpoint tests from your auth implementation — endpoint logic is testable
without a working JWT stack.

### Overriding external service clients

Same pattern for any injected service:

```python
class FakeEmailService:
    def __init__(self):
        self.sent: list[dict] = []

    def send_welcome(self, to: str) -> None:
        self.sent.append({"event": "welcome", "to": to})

    def send_goodbye(self, to: str) -> None:
        self.sent.append({"event": "goodbye", "to": to})

@pytest.fixture
def client_with_email():
    fake = FakeEmailService()
    app.dependency_overrides[get_email_service] = lambda: fake
    yield TestClient(app), fake
    app.dependency_overrides.clear()

def test_registration_sends_welcome(client_with_email):
    client, fake = client_with_email
    client.post("/users", json={"username": "alice", "email": "alice@x.com", "password": "pw"})
    assert any(e["event"] == "welcome" and e["to"] == "alice@x.com" for e in fake.sent)
```

Returning the fake alongside the client lets you assert on what the dependency *did*, not just
what the endpoint returned.

---

## BackgroundTasks vs a Real Task Queue

`BackgroundTasks` runs a function after the response is sent, in the same process, on the same
event loop. It is a convenience feature, not a task queue.

```python
from fastapi import BackgroundTasks

def send_email_background(to: str, subject: str) -> None:
    # called after the response is already sent
    email_client.send(to=to, subject=subject)

@router.post("/users", status_code=201)
def register(user: UserCreate, background_tasks: BackgroundTasks):
    db_user = create_user(user)
    background_tasks.add_task(send_email_background, to=user.email, subject="Welcome")
    return db_user
```

What `BackgroundTasks` does not give you:

- **Retries.** If the task raises, the exception is logged and the task is gone.
- **Persistence.** Restart the process → pending tasks are gone.
- **Visibility.** No dashboard, no dead-letter queue, no job status.
- **Distribution.** Tasks run in the same process that handled the request.

For anything where failure matters, use a real task queue:

| Queue | Install | Best for |
|-------|---------|----------|
| `arq` | `pip install arq` | asyncio-native; pairs naturally with FastAPI |
| `celery` | `pip install celery[redis]` | Mature ecosystem; massive feature set |
| `rq` | `pip install rq` | Simplest Redis-backed queue; sync only |

Pattern with `arq`:

```python
# worker.py
from arq import cron

async def send_welcome_email(ctx, to: str) -> None:
    await email_client.send(to=to, subject="Welcome")

class WorkerSettings:
    functions = [send_welcome_email]
    redis_settings = RedisSettings()

# in the route:
from arq import ArqRedis

@router.post("/users", status_code=201)
async def register(user: UserCreate, redis: ArqRedis = Depends(get_redis)):
    db_user = await create_user(user)
    await redis.enqueue_job("send_welcome_email", to=user.email)
    return db_user
```

The key distinction: enqueuing is durable (Redis survives restart), the worker retries on
failure, and the route returns `201` in microseconds regardless of email latency.

### Concurrency pitfalls with BackgroundTasks

Because background tasks share the same process:

- Shared mutable state (module-level lists, dicts) is a race condition waiting to trigger.
- CPU-bound tasks block the event loop — `run_in_executor` for anything that computes.
- Slow background tasks prevent the worker process from accepting new requests if you hit
  Gunicorn's `--timeout`.

```python
import asyncio
from fastapi import BackgroundTasks

# WRONG: this blocks the event loop for the duration of the sleep
def blocking_task():
    import time
    time.sleep(5)

# CORRECT: offload blocking work to a thread pool
async def safe_blocking_task():
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(None, blocking_task)
```

---

## Debugging Testing & Background Work

| Symptom | Cause | Fix |
|---------|-------|-----|
| `RuntimeError: This event loop is already running` | Running `asyncio.run()` or a blocking pytest-asyncio fixture inside a running loop | Use `asyncio_mode = "auto"` in pytest config; never call `asyncio.run()` in async tests |
| `ScopeMismatch: …session-scoped fixture 'X' uses async fixture 'Y' with a narrower scope` | Session-scoped async fixture not declaring `loop_scope="session"` | Add `loop_scope="session"` to the fixture decorator (pytest-asyncio ≥ 0.21) |
| Flaky async test: passes alone, fails in suite | Global state leaking between tests (module-level dict, `dependency_overrides` not cleared) | Always `app.dependency_overrides.clear()` in teardown; isolate state in per-test fixtures |
| Background task exception silently disappears | `BackgroundTasks` catches and logs the exception but does not propagate it | Add a global exception handler or use a task queue with retry; test the task function independently |
| `BackgroundTasks` work in tests but not production | Tests are synchronous; `TestClient` runs the background task before returning | For production: move long-running work to a real task queue; for test assertion: check side-effects after `client.post(...)` returns |
| Test suite passes locally, fails in CI with `connection refused` | Tests hit a real external service that isn't available in CI | Use `dependency_overrides` to inject a test double; never call real external services from tests |
| `assert r.status_code == 200` fails with 422 | Pydantic v2 validation is stricter — a field type mismatch now returns 422, not 500 | Read the `detail` field in the 422 response: it names the exact validation error |

> **War story.** A test suite at a previous job had 400 tests and ran green locally for months. CI would fail 30–50 tests depending on the run order — nondeterministic, no obvious pattern. Root cause: three test modules all imported a module-level `_email_log: list = []` from `notifications.py` and appended to it without reset. Module import is cached by Python — the list was shared across the entire pytest session. Tests that ran early in a fresh process passed; tests that ran after others in CI failed because the list already had entries from earlier tests. The fix was moving the list into a per-request fixture and using `dependency_overrides` to inject it. Shared mutable state at module level is test poison.

---

## Checkpoint

You're ready for the challenge when you can, without looking anything up:

1. State one scenario where `httpx.AsyncClient` is the right choice over `TestClient`, and one where it is not.
2. Write the `pyproject.toml` snippet that enables `asyncio_mode = "auto"` globally.
3. Write the `conftest.py` fixture pattern that overrides `get_db` with an in-memory SQLite database and cleans up correctly.
4. Explain why `app.dependency_overrides.clear()` must be in a teardown, not just at the end of the test body.
5. Name two things `BackgroundTasks` does NOT give you that a real task queue does.
6. Explain why a CPU-bound `BackgroundTasks` function degrades API throughput.
7. Describe the "shared mutable state" test isolation failure mode and the fix.

➡ **Challenge 05 — Test Doubles** tests exactly these skills. Run `setup.sh` to get the skeleton.
