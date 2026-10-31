# Testing & Logging

> **Module 05 · Course 12** — An untested Flask app is a flask of unknown contents. A Flask app without structured logging is dark in production. This module covers both: pytest patterns that don't fight the app factory, and JSON logging that gives you actionable signal when something fails — without drowning you in noise.

The traps here aren't about knowing pytest. They're about knowing how Flask's application context interacts with pytest fixtures, and about knowing that `app.logger.info("user created")` is nearly useless in a log aggregator.

---

## pytest + the Flask test client

### The app factory dance

The Flask test client requires a live app instance. That means your test suite needs the app factory:

```python
# tests/conftest.py
import pytest
from app import create_app
from app.extensions import db as _db

@pytest.fixture(scope="session")
def app():
    """Session-scoped — creates the app once for the entire test run."""
    app = create_app("testing")   # TestingConfig: in-memory SQLite, TESTING=True
    with app.app_context():
        _db.create_all()
        yield app
        _db.drop_all()

@pytest.fixture(scope="function")
def client(app):
    return app.test_client()

@pytest.fixture(scope="function", autouse=True)
def db_session(app):
    """Wrap each test in a transaction, roll back on teardown — no state leaks."""
    with app.app_context():
        connection = _db.engine.connect()
        transaction = connection.begin()
        _db.session.bind = connection

        yield _db.session

        transaction.rollback()
        connection.close()
        _db.session.remove()
```

The `db_session` fixture is the key to test isolation: every test runs inside a real transaction that gets rolled back, so nothing bleeds into the next test. The `scope="session"` app fixture avoids recreating the app (and re-running schema creation) for every test file.

**The scope mismatch:** a `scope="session"` fixture can feed a `scope="function"` one (session outlives function). The reverse raises `ScopeMismatch`. Draw the scope dependency graph if you get that error.

**`TESTING=True` in config matters:** it disables error propagation to error handlers, so raw exceptions surface in test output instead of being swallowed into a 500 response. Set it explicitly:

```python
# config.py
class TestingConfig:
    TESTING = True
    SQLALCHEMY_DATABASE_URI = "sqlite:///:memory:"
    WTF_CSRF_ENABLED = False
    LOG_LEVEL = "WARNING"
```

### Writing tests with the test client

```python
# tests/test_users.py
import json

def test_create_user_returns_201(client):
    resp = client.post(
        "/api/v1/users",
        data=json.dumps({"email": "a@example.com", "name": "Alice"}),
        content_type="application/json",
    )
    assert resp.status_code == 201
    body = resp.get_json()
    assert body["email"] == "a@example.com"


def test_create_user_missing_email_returns_422(client):
    resp = client.post(
        "/api/v1/users",
        data=json.dumps({"name": "Alice"}),
        content_type="application/json",
    )
    assert resp.status_code == 422
    body = resp.get_json()
    assert body["error"]["code"] == "VALIDATION_ERROR"
    # confirm the details array points at the right field
    locs = [d["loc"] for d in body["error"]["details"]]
    assert ["email"] in locs


def test_health_returns_ok(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"
```

`resp.get_json()` handles the content-type check internally — if the response isn't JSON it returns `None` rather than raising. Always assert `status_code` before asserting the body so test failures are readable.

**Auth headers:**

```python
def test_authenticated_endpoint(client, user_token):
    resp = client.get(
        "/api/v1/profile",
        headers={"Authorization": f"Bearer {user_token}"},
    )
    assert resp.status_code == 200
```

`user_token` is a fixture that creates a user and generates a valid JWT — factory-boy is the right tool for that.

---

## factory-boy: generate test data without fixture rot

Manual `{"email": "test@example.com", "name": "Test User"}` dicts spread across hundreds of tests. When a field is added to the schema, everything breaks. factory-boy centralizes the problem:

```python
# tests/factories.py
import factory
from factory.alchemy import SQLAlchemyModelFactory
from app.models import User
from app.extensions import db

class UserFactory(SQLAlchemyModelFactory):
    class Meta:
        model = User
        sqlalchemy_session = db.session
        sqlalchemy_session_persistence = "commit"

    id = factory.Sequence(lambda n: n + 1)
    email = factory.LazyAttribute(lambda o: f"user{o.id}@example.com")
    name = factory.Faker("name")
    age = factory.Faker("random_int", min=18, max=80)
    is_active = True
```

```python
def test_list_users_returns_only_active(client, db_session):
    UserFactory.create_batch(3, is_active=True)
    UserFactory.create(is_active=False)

    resp = client.get("/api/v1/users")
    assert resp.status_code == 200
    assert len(resp.get_json()["data"]) == 3
```

`factory.Sequence` guarantees unique values across the test run. `factory.Faker` delegates to the Faker library — realistic values without manual bookkeeping.

**Nested objects:**

```python
class PostFactory(SQLAlchemyModelFactory):
    class Meta:
        model = Post
        sqlalchemy_session = db.session

    author = factory.SubFactory(UserFactory)
    title = factory.Faker("sentence", nb_words=5)
    body = factory.Faker("paragraph")
```

`SubFactory` creates the related object automatically. No more "create a user first, store its ID, pass it in" boilerplate in every test that needs a post.

---

## Coverage: what 80% actually means

```bash
pip install pytest-cov

pytest --cov=app --cov-report=term-missing --cov-fail-under=80
```

`--cov-report=term-missing` shows the exact line ranges not covered — the only view worth reading. `--cov-fail-under=80` exits non-zero if coverage drops below 80%, which CI catches.

**Branch coverage is more honest than line coverage:**

```bash
pytest --cov=app --cov-branch --cov-report=term-missing
```

A function with `if condition: return X` counts as "covered" at line level even if `condition` is always true in tests. Branch coverage requires both the true and false paths to be exercised.

```ini
# pytest.ini
[pytest]
addopts = --cov=app --cov-branch --cov-report=term-missing --cov-fail-under=80
testpaths = tests
```

What 80% means: the happy path and main error paths are covered. It does **not** mean the tests are good — 80% coverage with assertions only on `status_code == 200` is a number, not a test suite. The metric is a floor, not a ceiling. The `term-missing` output is the real signal: if the uncovered lines are your error handlers and edge cases, that's where your next tests go.

---

## Structured JSON logging

`app.logger.info("user created")` is a free-text string in a file. In a log aggregator (Loki, Datadog, Elastic) you can't query it reliably. Structured logging emits JSON objects — every field is queryable.

```python
# app/logging_config.py
import logging
import sys
from pythonjsonlogger import jsonlogger   # pip install python-json-logger

def configure_logging(app):
    handler = logging.StreamHandler(sys.stdout)
    formatter = jsonlogger.JsonFormatter(
        "%(asctime)s %(name)s %(levelname)s %(message)s",
        rename_fields={"asctime": "ts", "levelname": "level", "name": "logger"},
    )
    handler.setFormatter(formatter)

    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(app.config.get("LOG_LEVEL", "INFO"))

    logging.getLogger("sqlalchemy.engine").setLevel(logging.WARNING)
    logging.getLogger("werkzeug").setLevel(logging.WARNING)
```

A log call with `extra=` kwargs becomes:

```python
app.logger.info("user created", extra={"user_id": user.id, "email": user.email})
```

```json
{"ts": "2026-01-15T10:23:44.123Z", "level": "INFO", "logger": "app.api.users",
 "message": "user created", "user_id": 42, "email": "a@example.com"}
```

Every key in `extra` becomes a top-level key. That's what makes it queryable: in Loki you'd write `{app="my-api"} | json | user_id=42` and see every log line for that user.

---

## Request IDs

Request IDs let you correlate all log lines from a single HTTP request — invaluable when one request triggers five DB queries and two downstream calls:

```python
# app/middleware.py
import uuid
from flask import g, request

def register_request_id(app):

    @app.before_request
    def set_request_id():
        g.request_id = request.headers.get("X-Request-Id") or str(uuid.uuid4())

    @app.after_request
    def echo_request_id(response):
        response.headers["X-Request-Id"] = g.request_id
        return response
```

To include it automatically in every log line:

```python
import logging
from flask import g, has_request_context

class RequestIdFilter(logging.Filter):
    def filter(self, record):
        record.request_id = g.request_id if has_request_context() else "-"
        return True
```

Add the filter to the handler and include `%(request_id)s` in the formatter string. Now `grep '"request_id": "abc-123"'` gives you the full lifecycle of one request across all log lines.

---

## Log levels: what goes where

| Level | When to use | Examples |
|-------|-------------|---------|
| `DEBUG` | Internal state only useful while developing | SQL queries, request/response bodies, cache hit/miss |
| `INFO` | Normal operational events worth recording | User created, payment processed, job enqueued |
| `WARNING` | Unexpected but the system continued | Deprecated endpoint called, retried a flaky dependency |
| `ERROR` | An operation failed and someone should know | DB write failed, email not sent, external API 5xx |
| `CRITICAL` | The system cannot continue | DB pool exhausted, filesystem full |

Production default is `INFO`. Never run `DEBUG` in production — it leaks internal state and saturates log storage. Switch it temporarily with an env var, not a code change:

```python
class ProductionConfig:
    LOG_LEVEL = "INFO"
    DEBUG = False

class DevelopmentConfig:
    LOG_LEVEL = "DEBUG"
    DEBUG = True

class TestingConfig:
    LOG_LEVEL = "WARNING"   # suppress INFO/DEBUG noise during tests
    TESTING = True
```

---

## Debugging Testing & Logging

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Tests pass in isolation, fail when run together | Tests sharing state via `db.session` or module-level variables | Use the transaction rollback `db_session` fixture; never `db.session.commit()` in a test unless you're explicitly testing commit behavior |
| Test fails intermittently, passes on re-run | Time-dependent logic (`datetime.now()`), undeterministic ordering of dicts, or a `sleep()` race | Freeze time with `freezegun`; sort results before asserting; run `pytest --randomly-seed=last` to reproduce the failing order |
| `INFO` logs appear in test terminal output | `LOG_LEVEL` is `INFO` in `TestingConfig` | Set `LOG_LEVEL = "WARNING"` in the testing config |
| Logs appear in dev but not under gunicorn/Docker | gunicorn buffers stdout; or `configure_logging` is called after the first `app.logger` use | Set `PYTHONUNBUFFERED=1` in the container; call `configure_logging(app)` as the last step inside `create_app` before returning; set `--access-logfile=-` for gunicorn |
| `RuntimeError: Working outside of application context` in a test | A fixture uses `db.session` without entering an `app_context()` | Wrap the fixture body in `with app.app_context():` |
| factory-boy generates duplicate emails, causing DB unique constraint failures | `factory.Faker("email")` doesn't guarantee uniqueness | Use `factory.LazyAttribute(lambda o: f"user{o.id}@example.com")` with `factory.Sequence` for the ID |

### Exact diagnosis commands

```bash
# Run a single test with verbose output
pytest tests/test_users.py::test_create_user_returns_201 -v

# See exactly which lines are not covered
pytest --cov=app --cov-branch --cov-report=term-missing

# Show log output live during a test run (pytest suppresses it by default)
pytest -s --log-cli-level=DEBUG tests/test_users.py

# Find order-dependent test failures
pip install pytest-randomly
pytest --randomly-seed=random -v          # different seed each run
pytest --randomly-seed=last -v            # repeat last failing seed

# Confirm structured logging emits valid JSON
python3 -c "
from app import create_app
app = create_app('development')
with app.app_context():
    app.logger.info('test event', extra={'user_id': 1, 'action': 'login'})
" 2>&1 | python3 -m json.tool

# Test request ID propagation
curl -s -H 'X-Request-Id: my-trace-id-123' http://localhost:5000/health -i | grep X-Request-Id
```

> **War story.** Our CI suite ran green for three months, then suddenly 40% of tests started failing on Monday mornings. Root cause: a weekly cleanup job ran on Sunday nights against what it thought was the staging database, which happened to share a hostname with the CI runner's SQLite file path (the test config was wrong). Every test run built on whatever schema state the cleanup script left. The fix was two lines: point `TestingConfig.SQLALCHEMY_DATABASE_URI` at `"sqlite:///:memory:"`, and call `_db.create_all()` inside the session-scoped `app` fixture. Tests that exercise database code should own their database entirely — never share it with anything else.

---

## Checkpoint

You're ready for the challenge when you can:

1. Write a session-scoped `app` fixture and a function-scoped `db_session` fixture that rolls back each test with no state leakage.
2. Use the Flask test client to POST a JSON body and assert both the status code and the exact shape of the JSON response.
3. Define a factory-boy factory for a SQLAlchemy model with uniqueness guaranteed on email.
4. Run branch coverage, read the `term-missing` output, and identify which line ranges need new tests.
5. Configure `python-json-logger` so every log line is a valid JSON object; add `user_id` and `action` fields to a single `logger.info()` call using `extra={}`.
6. Add request ID middleware that reads `X-Request-Id` from incoming headers or generates a UUID, echoes it in the response headers, and injects it into every log line.
7. Explain in one sentence why `LOG_LEVEL = "WARNING"` is the right choice for `TestingConfig`.

➡ Next up: the **Log and Prove It** challenge — you'll write tests for a working Flask app and push branch coverage above 80%.
