# Solution — Test Doubles with dependency_overrides

## `tests/conftest.py` — complete implementation

```python
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest
from fastapi.testclient import TestClient
from main import app, get_notifier


class RecordingNotifier:
    def __init__(self):
        self.calls: list[dict] = []

    def send_welcome(self, username: str) -> None:
        self.calls.append({"event": "welcome", "username": username})

    def send_goodbye(self, username: str) -> None:
        self.calls.append({"event": "goodbye", "username": username})


@pytest.fixture
def recorder():
    yield RecordingNotifier()


@pytest.fixture
def client(recorder):
    app.dependency_overrides[get_notifier] = lambda: recorder
    yield TestClient(app)
    app.dependency_overrides.clear()
```

## `tests/test_app.py` — filled-in assertions

```python
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import main as m


def setup_function():
    m._users.clear()


def test_create_user_calls_welcome(client, recorder):
    r = client.post("/users", json={"username": "bob"})
    assert r.status_code == 201, f"expected 201, got {r.status_code}"
    assert any(
        c["event"] == "welcome" and c["username"] == "bob" for c in recorder.calls
    ), "send_welcome was not called with 'bob'"


def test_duplicate_user_returns_409(client, recorder):
    client.post("/users", json={"username": "carol"})
    r = client.post("/users", json={"username": "carol"})
    assert r.status_code == 409


def test_delete_user_calls_goodbye(client, recorder):
    client.post("/users", json={"username": "dave"})
    r = client.delete("/users/dave")
    assert r.status_code == 204, f"expected 204, got {r.status_code}"
    assert any(
        c["event"] == "goodbye" and c["username"] == "dave" for c in recorder.calls
    ), "send_goodbye was not called with 'dave'"
```

## Why each piece matters

**`app.dependency_overrides[get_notifier] = lambda: recorder`** — the map key is the exact
function object, not a string. FastAPI resolves dependencies by identity (`is`, not `==`), so
you must import and use the same function object the app uses. Importing from a different path
(`from app import get_notifier` vs `from main import get_notifier`) that results in a different
object will silently fail to override.

**`lambda: recorder`** — the override must be a callable that FastAPI can inject. A plain
`recorder` (the instance) would not work; wrapping it in a lambda gives FastAPI a callable
that returns the shared instance, so `recorder.calls` is the same list the tests read.

**`app.dependency_overrides.clear()` in teardown** — if you omit this, the override persists
into subsequent tests in the same session. Python modules are imported once per process; a
leaked override in `test_create_user_calls_welcome` would make `test_duplicate_user_returns_409`
use the same `RecordingNotifier` from a different test, leading to mysterious cross-test
contamination.

**`setup_function()`** — clears `_users` (the module-level list in `main.py`) before each test.
Without this, a user created in one test persists into the next, making `test_duplicate_user_returns_409`
fail if `test_create_user_calls_welcome` ran first with the same username. This is the "shared
mutable state" failure mode from Module 05.

## Attacker's view

This pattern also has a security implication: any code path that touches `app.dependency_overrides`
in a production process (e.g., an inadvertently exposed admin endpoint) can replace any dependency —
including auth. In production, `dependency_overrides` must be empty and any attempt to mutate it
should be treated as a critical vulnerability.
