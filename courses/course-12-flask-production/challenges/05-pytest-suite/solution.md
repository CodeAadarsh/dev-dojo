# Solution — Test the App You Didn't Write

Read `app.py` once to identify the three routes and their contracts, then encode each contract as at least one assertion.

```python
# tests/test_app.py
import pytest
from app import create_app


@pytest.fixture
def client():
    app = create_app()
    app.config['TESTING'] = True
    with app.test_client() as c:
        yield c


def test_health_returns_200(client):
    rv = client.get('/health')
    assert rv.status_code == 200, f"expected 200, got {rv.status_code}"


def test_health_body(client):
    rv = client.get('/health')
    body = rv.get_json()
    assert body is not None, "/health did not return JSON"
    assert body.get('status') == 'ok', f"expected status 'ok', got {body.get('status')}"


def test_create_task_returns_201(client):
    rv = client.post('/tasks', json={'title': 'Buy milk'})
    assert rv.status_code == 201, f"expected 201, got {rv.status_code}"


def test_create_task_has_id(client):
    rv = client.post('/tasks', json={'title': 'Read the docs'})
    assert rv.status_code == 201
    body = rv.get_json()
    assert body is not None, "POST /tasks did not return JSON"
    assert 'id' in body, f"response body missing 'id': {body}"


def test_get_task_returns_200(client):
    create = client.post('/tasks', json={'title': 'Deploy the thing'})
    assert create.status_code == 201
    task_id = create.get_json()['id']
    rv = client.get(f'/tasks/{task_id}')
    assert rv.status_code == 200, f"expected 200, got {rv.status_code}"


def test_get_missing_task_returns_404(client):
    rv = client.get('/tasks/999999')
    assert rv.status_code == 404, f"expected 404, got {rv.status_code}"
```

## Why each piece matters

**`app.test_client()` in a fixture.** Flask's test client drives the WSGI app in-process — no network socket, no port to bind, no timing issues. The `create_app()` factory pattern means each test gets a fresh app with a clean `_tasks` store; without it, state from one test leaks into the next.

**Create then fetch in `test_get_task_returns_200`.** You can't hardcode an ID because `_next_id` increments across tests in the same process. Always create the resource in the same test that reads it; take the `id` from the creation response. This pattern works for any auto-increment store.

**`test_get_missing_task_returns_404` uses an ID that will never exist.** `999999` is high enough that no realistic number of `create_task` calls in the test suite will reach it. Alternatively, fetch immediately after setup before creating anything — but the large constant is simpler to read.

**Why the verifier greps for function names first.** A `NotImplementedError` raises, pytest marks the test as ERROR (not FAILED), and the exit code is still non-zero. Grepping for the function names catches the case where a learner renamed the functions or deleted them, giving a clearer error message than "pytest error."

## What good test coverage looks like beyond this challenge

- `POST /tasks` with an empty `title` → 422 (the negative path is already handled in the app).
- `GET /tasks/<id>` body shape: `{'id': ..., 'title': ..., 'done': False}`.
- Idempotency: two POSTs with the same title produce two different IDs.

These are left as an exercise; the verifier only requires the six listed functions.
