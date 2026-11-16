# Test a Real API End-to-End

## The setup

The capstone. A small FastAPI "notes" service with full CRUD, error handling, shared in-memory state, and one endpoint that calls an **external** API. You'll test it the way a professional does: in-process with `TestClient` (no running server), asserting on status codes *and* bodies, isolating the shared state so tests don't pollute each other, and mocking the external call. The network is blocked, so the enrichment endpoint **must** be mocked. Catch every planted bug.

This pulls together the whole course: fixtures (isolation), parametrization (error cases), mocking (the boundary), and strong assertions.

## The code under test

`setup.sh` plants `api.py`:

```python
import requests
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI()
_db = {}
_next_id = {"v": 1}

class NoteIn(BaseModel):
    title: str
    body: str = ""

@app.post("/notes", status_code=201)
def create_note(note: NoteIn):
    if not note.title.strip():
        raise HTTPException(status_code=422, detail="title required")
    nid = _next_id["v"]; _next_id["v"] += 1
    _db[nid] = {"id": nid, "title": note.title, "body": note.body}
    return _db[nid]

@app.get("/notes/{nid}")
def get_note(nid: int):
    if nid not in _db:
        raise HTTPException(status_code=404, detail="not found")
    return _db[nid]

@app.get("/notes")
def list_notes():
    return list(_db.values())

@app.delete("/notes/{nid}", status_code=204)
def delete_note(nid: int):
    if nid not in _db:
        raise HTTPException(status_code=404, detail="not found")
    del _db[nid]

@app.get("/notes/{nid}/enrich")
def enrich(nid: int):
    if nid not in _db:
        raise HTTPException(status_code=404, detail="not found")
    resp = requests.get(f"https://api.example.com/wordcount?text={_db[nid]['body']}")
    resp.raise_for_status()
    return {"id": nid, "word_count": resp.json()["count"]}
```

## The spec

1. `POST /notes` with a valid body → **201**, returns the note with a generated `id`, `title`, `body`.
2. `POST /notes` with a blank/whitespace title → **422**.
3. `GET /notes/{id}` → **200** with the note; a missing id → **404**.
4. `GET /notes` → **200** with a list of all notes.
5. `DELETE /notes/{id}` → **204** and the note is gone (a subsequent `GET` is **404**); deleting a missing id → **404**.
6. `GET /notes/{id}/enrich` → calls the external word-count API and returns `{"id", "word_count"}` from the API's `count` field; a missing id → **404**.

## Your mission — and the rules

Write tests in `test_api.py`. Provided in the starter: a `client` fixture (`TestClient`) and an **autouse reset fixture** that clears `_db`/`_next_id` before each test — because the state is a module global, without it tests leak into each other (that's the isolation lesson, handed to you). You must:

- Use **`TestClient`** (the verifier checks for it).
- Cover every rule, asserting on **status codes AND response bodies**.
- For `enrich`, **mock `api.requests`** (the network is blocked). Patch where it's used: `patch("api.requests")`, with `mock_requests.get.return_value.json.return_value = {"count": 3}`.

The verifier runs your suite against the correct app (network blocked — must pass) and against mutants with a wrong create status, a missing 404 check, a broken delete, a missing title validation, and a wrong enrich field (must fail on each).

## Verify & flag

```bash
bash courses/course-36-python-testing/challenges/07-test-a-real-api/setup.sh
# needs: pip install pytest fastapi httpx requests
# write tests in ~/.kube-dojo-work/07-test-a-real-api/test_api.py
bash courses/course-36-python-testing/challenges/07-test-a-real-api/verify.sh
```
