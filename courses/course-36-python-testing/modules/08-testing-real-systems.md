# Testing Real Systems — APIs, Databases & CI

> **Module 08 · Course 36** — Unit tests on pure functions are the easy part. Real applications have an HTTP layer, a database, external services, and a CI pipeline that must run all of it on every push. This capstone module shows how to test a web API with a test client (no running server), how to give each database test a clean, isolated world via transaction rollback, how to keep a suite fast and non-flaky at scale, and how to wire pytest into GitHub Actions. It ties together everything: fixtures, mocking, parametrization, coverage, and the test pyramid that tells you how much of each to write.

---

## The test pyramid — how much of each

Not all tests are equal in cost or value. The classic shape:

```
          ╱╲          few   — End-to-end (browser, full stack): slow, flaky, high confidence
         ╱  ╲
        ╱    ╲        some  — Integration (API + real DB): medium speed, real wiring
       ╱──────╲
      ╱        ╲      many  — Unit (pure logic, mocked boundaries): fast, precise, cheap
     ╱──────────╲
```

- **Many unit tests** — milliseconds each, pinpoint failures, run constantly.
- **Some integration tests** — your API talking to a real (test) database, proving the pieces fit.
- **Few end-to-end tests** — the whole system; expensive and flakier, so reserve them for critical user journeys.

The anti-pattern is the **ice-cream cone** (inverted pyramid): mostly slow E2E tests, few units. It's slow, flaky, and failures don't tell you *where* the bug is. Push logic down into unit tests; keep a thin layer of integration tests for wiring.

---

## Testing an HTTP API without a server

You don't start a real server and `requests.get` it — that's slow and racy. Web frameworks ship a **test client** that routes requests through the app in-process. For FastAPI (built on Starlette), it's `TestClient`:

```python
# app.py
from fastapi import FastAPI, HTTPException
app = FastAPI()
_users = {1: {"id": 1, "name": "Ada"}}

@app.get("/users/{user_id}")
def get_user(user_id: int):
    if user_id not in _users:
        raise HTTPException(status_code=404, detail="not found")
    return _users[user_id]
```

```python
# test_app.py
from fastapi.testclient import TestClient
from app import app

client = TestClient(app)

def test_get_existing_user():
    resp = client.get("/users/1")
    assert resp.status_code == 200
    assert resp.json() == {"id": 1, "name": "Ada"}

def test_get_missing_user_404():
    resp = client.get("/users/999")
    assert resp.status_code == 404
    assert resp.json()["detail"] == "not found"
```

The client calls your app directly — no network, no port, no race. You assert on the status code, the JSON body, and headers. Make the client a fixture so tests share it:

```python
import pytest
from fastapi.testclient import TestClient
from app import app

@pytest.fixture
def client():
    with TestClient(app) as c:      # context form runs startup/shutdown events
        yield c
```

(Flask is the same shape: `app.test_client()`. Django: `django.test.Client`. The principle — in-process client, assert on the response — is universal.)

---

## Testing with a real database, isolated

Integration tests should hit a *real* database (SQLite in-memory, or a disposable Postgres), because that's where schema bugs, constraints, and SQL mistakes surface — things a mock can never catch. The challenge is **isolation**: each test must start from a known state and not see another test's writes.

Two reliable patterns:

### Pattern A — transaction rollback (fast, preferred)

Wrap each test in a transaction and roll it back in teardown. Nothing a test writes ever commits, so every test gets a pristine DB with zero cleanup cost:

```python
@pytest.fixture
def db_session(engine):
    connection = engine.connect()
    transaction = connection.begin()
    session = Session(bind=connection)
    yield session
    session.close()
    transaction.rollback()      # undo everything the test did
    connection.close()
```

This is the gold standard for speed + isolation: the rollback is instant and total.

### Pattern B — recreate schema per test (simple, slower)

```python
@pytest.fixture
def db():
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(engine)     # fresh tables
    yield engine
    Base.metadata.drop_all(engine)
```

In-memory SQLite makes this cheap enough for smaller suites. For large suites, prefer rollback.

### Seeding test data with factory fixtures

Combine with the factory pattern (Module 03) so each test declares the data it needs:

```python
@pytest.fixture
def make_user(db_session):
    def _make(name="test", **kw):
        u = User(name=name, **kw)
        db_session.add(u); db_session.flush()
        return u
    return _make

def test_user_appears_in_list(client, make_user):
    make_user(name="Ada")
    resp = client.get("/users")
    assert any(u["name"] == "Ada" for u in resp.json())
```

### Overriding dependencies so the app uses the test DB

Your app has a dependency that provides the real database; in tests you override it to hand over the test session. FastAPI makes this first-class:

```python
from app import app, get_db

def test_with_override(db_session):
    app.dependency_overrides[get_db] = lambda: db_session
    client = TestClient(app)
    # ... now the app reads/writes the isolated test session
    app.dependency_overrides.clear()     # always clean up (or do it in a fixture)
```

This is the seam that lets integration tests use a disposable database while the app code stays unchanged.

---

## Keeping a real-world suite fast and honest

As suites grow into the thousands, two problems dominate: speed and flakiness.

### Parallelize with `pytest-xdist`

```bash
pip install pytest-xdist
pytest -n auto          # spread tests across all CPU cores
```

`-n auto` can cut wall-clock time several-fold. The catch: parallel tests **must** be independent — no shared files, no shared DB rows, no ordering assumptions. If parallelizing breaks your suite, you have hidden coupling (a real bug worth fixing). Give each worker its own temp dir (`tmp_path` is already per-test) and its own DB schema/transaction.

### Kill flakiness

A flaky test (passes sometimes, fails sometimes) is worse than no test — it trains the team to ignore red. Causes and fixes:

- **Time** — `datetime.now()`, timeouts, sleeps. Freeze the clock (Module 05); never `sleep` to "wait for" something — poll or await.
- **Randomness** — seed it or mock it.
- **Order dependence** — a test relying on another's leftovers. Isolate state (rollback, fresh fixtures). Run with `pytest-randomly` to shuffle order and *expose* the coupling.
- **Real network** — block sockets in a fixture (Module 05) so an un-mocked call fails loudly instead of flaking.
- **Shared mutable globals** — reset in an `autouse` fixture.

Quarantine, don't ignore: mark a known-flaky test `@pytest.mark.flaky` (via `pytest-rerunfailures`) only as a temporary measure while you fix the root cause.

---

## Wiring pytest into CI (GitHub Actions)

CI runs your suite on every push and blocks merges when it's red. A minimal, real workflow:

```yaml
# .github/workflows/tests.yml
name: tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        python-version: ["3.11", "3.12"]   # test across versions
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: ${{ matrix.python-version }}
      - name: Install
        run: |
          python -m pip install --upgrade pip
          pip install -e ".[test]"          # your package + test extras
      - name: Run tests
        run: pytest -n auto --cov=myproject --cov-branch --cov-fail-under=85 -ra
```

What each piece buys you:

- **`matrix.python-version`** — runs the whole suite on 3.11 *and* 3.12, catching version-specific breakage.
- **`pytest -n auto`** — parallel, fast feedback.
- **`--cov-branch --cov-fail-under=85`** — coverage can't silently erode; the job fails if it drops.
- **`-ra`** — a summary of everything non-passing at the end, so a failed run is readable in the CI log.

For integration tests needing a real Postgres, add a service container:

```yaml
    services:
      postgres:
        image: postgres:16
        env: { POSTGRES_PASSWORD: test }
        ports: ["5432:5432"]
        options: >-
          --health-cmd pg_isready --health-interval 10s
          --health-timeout 5s --health-retries 5
```

Then point your test DB URL at `localhost:5432`. This is the same pattern the rest of the dojo uses — fast unit tests on every push, heavier integration tests against a real service in CI.

---

## Debugging

- **`TestClient` import fails.** FastAPI's `TestClient` needs `httpx` installed (`pip install httpx`). The import is `from fastapi.testclient import TestClient`.
- **Integration test leaves rows behind / next test sees stale data.** Your isolation is broken — you committed instead of rolling back, or the app used the *real* DB because you forgot the dependency override. Verify the override is set and cleared, and that the session the app uses is the one your fixture rolls back.
- **Tests pass serially but fail with `-n auto`.** Hidden coupling: shared file, shared DB rows, a global, or order dependence. Each must be independent. Give workers isolated resources; this failure is a real bug, not an xdist quirk.
- **App startup/shutdown logic (DB pool, cache) doesn't run in tests.** Use `with TestClient(app) as c:` — the context-manager form triggers lifespan/startup events; the bare `TestClient(app)` may not.
- **`dependency_overrides` leaks into other tests.** You didn't clear it. Set and clear it inside a fixture (`yield`, then `app.dependency_overrides.clear()`), not inline.
- **CI green locally, red in Actions (or vice versa).** Environment drift: unpinned deps, a service not ready (add health checks), a timezone/locale difference, or a test depending on local files. Pin versions and make tests environment-independent.
- **Coverage lower in CI than locally.** You ran a subset locally (`-k`/`-m`) or skipped slow tests. CI runs everything — measure the full suite locally before trusting the number.

---

## Checkpoint

You can now:

- Explain the test pyramid and why the ice-cream-cone anti-pattern is slow and uninformative.
- Test an HTTP API in-process with a test client, asserting on status, body, and headers — no running server.
- Isolate database tests with transaction rollback (preferred) or schema recreate, seed data with factory fixtures, and override the app's DB dependency to use a disposable test database.
- Parallelize with `pytest-xdist -n auto` and understand that a break under parallelism reveals real coupling.
- Diagnose and eliminate flakiness (time, randomness, order, network, globals).
- Wire pytest into GitHub Actions with a version matrix, coverage gate, and a Postgres service container.

**Course capstone self-test:** you join a team whose suite is 95% coverage, all green, yet production breaks weekly. Name three things you'd check and the fix for each. (1 — assert quality: run a mutation tester; weak/missing asserts → add real assertions. 2 — the pyramid shape: mostly mocked unit tests, no integration layer → add API+DB integration tests so wiring is exercised. 3 — flakiness being ignored/retried into green → fix root causes, block merges on red.) That's the whole course: from your first `assert` to grading an entire team's test strategy. The challenges will prove you can do it — every verifier mutates the code and dares your tests to notice.
