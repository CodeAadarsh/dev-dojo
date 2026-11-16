# Solution — Test a Real API End-to-End

```python
# test_api.py
import pytest
from unittest.mock import patch
from fastapi.testclient import TestClient
import api


@pytest.fixture(autouse=True)
def reset_state():
    api._db.clear()
    api._next_id["v"] = 1
    yield


@pytest.fixture
def client():
    return TestClient(api.app)


# ── create ──────────────────────────────────────────────────────────────────
def test_create_returns_201_and_note(client):
    resp = client.post("/notes", json={"title": "Buy milk", "body": "2L"})
    assert resp.status_code == 201               # catches 'create returns 200'
    note = resp.json()
    assert note == {"id": 1, "title": "Buy milk", "body": "2L"}

@pytest.mark.parametrize("bad_title", ["", "   ", "\t"])
def test_blank_title_rejected(client, bad_title):
    resp = client.post("/notes", json={"title": bad_title})
    assert resp.status_code == 422               # catches 'no title validation'


# ── read ──────────────────────────────────────────────────────────────────
def test_get_existing(client):
    nid = client.post("/notes", json={"title": "x"}).json()["id"]
    resp = client.get(f"/notes/{nid}")
    assert resp.status_code == 200
    assert resp.json()["title"] == "x"

def test_get_missing_is_404(client):
    assert client.get("/notes/999").status_code == 404   # catches 'get no 404'

def test_list_returns_all(client):
    client.post("/notes", json={"title": "a"})
    client.post("/notes", json={"title": "b"})
    resp = client.get("/notes")
    assert resp.status_code == 200
    titles = [n["title"] for n in resp.json()]
    assert titles == ["a", "b"]


# ── delete ──────────────────────────────────────────────────────────────────
def test_delete_removes_note(client):
    nid = client.post("/notes", json={"title": "x"}).json()["id"]
    resp = client.delete(f"/notes/{nid}")
    assert resp.status_code == 204
    assert client.get(f"/notes/{nid}").status_code == 404   # catches 'delete noop'

def test_delete_missing_is_404(client):
    assert client.delete("/notes/999").status_code == 404


# ── enrich (mock the external boundary) ──────────────────────────────────────
def test_enrich_uses_count_field(client):
    nid = client.post("/notes", json={"title": "x", "body": "one two three"}).json()["id"]
    with patch("api.requests") as mock_requests:
        mock_requests.get.return_value.json.return_value = {"count": 3}
        resp = client.get(f"/notes/{nid}/enrich")
    assert resp.status_code == 200
    assert resp.json() == {"id": nid, "word_count": 3}   # catches 'wrong enrich field'

def test_enrich_missing_is_404(client):
    assert client.get("/notes/999/enrich").status_code == 404
```

## Why each piece is correct

- **`TestClient(api.app)`** runs requests through the ASGI app in-process — no server, no port, no real socket (which is why the network block doesn't interfere with normal requests but *does* catch the un-mocked external call).
- **The autouse `reset_state` fixture is the isolation lesson.** `_db` and `_next_id` are module globals — they persist across tests within a run. Without the reset, `test_list_returns_all` would see notes left by earlier tests and the `id == 1` assertion in `test_create` would fail depending on order. Resetting before each test makes every test start from a known world, so they pass in any order and in parallel. **Shared state is the #1 source of order-dependent flakiness; a reset fixture is the cure.**
- **Assert status AND body.** A test that only checks `status_code == 201` would miss a bug that returns the wrong note. Checking the full body (`note == {...}`) pins both.
- **`patch("api.requests")`** — `api.py` did `import requests`, so the name lives in the `api` namespace. The chained `.get.return_value.json.return_value = {"count": 3}` fakes `requests.get(...).json()`. Asserting `word_count == 3` is what catches the mutant that reads the wrong field — if you'd only asserted `status_code == 200`, a `{"words": ...}` bug would 500 and you'd... actually catch it by the 500, but asserting the value is the robust check.

## The whole course, in one test file

This challenge is every module at once: **fixtures** for the client and isolation, **parametrize** for the blank-title variants, **mocking** for the external boundary (patched where used, network blocked to force it), and **strong assertions** on status *and* body. The test pyramid in practice: these are fast, isolated, in-process tests — the wide base. In a real project you'd add one or two integration tests against a real database and a contract test against the real word-count API, run separately in CI. But this suite is what runs on every push, in under a second, and keeps the service honest.
