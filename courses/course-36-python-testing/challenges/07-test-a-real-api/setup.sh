#!/usr/bin/env bash
# Plants the "Test a Real API End-to-End" capstone exercise.
set -euo pipefail

SLUG="07-test-a-real-api"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

cat > "$WORK/api.py" << 'PYEOF'
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
    nid = _next_id["v"]
    _next_id["v"] += 1
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
PYEOF

if [ ! -f "$WORK/test_api.py" ]; then
cat > "$WORK/test_api.py" << 'PYEOF'
import pytest
from unittest.mock import patch
from fastapi.testclient import TestClient
import api


# Isolation: the service stores notes in module globals. Reset them before each
# test so tests don't leak into one another (this is handed to you — study it).
@pytest.fixture(autouse=True)
def reset_state():
    api._db.clear()
    api._next_id["v"] = 1
    yield


@pytest.fixture
def client():
    return TestClient(api.app)


# Example — create then read back.
def test_create_then_get(client):
    resp = client.post("/notes", json={"title": "Buy milk", "body": "2L"})
    assert resp.status_code == 201
    note = resp.json()
    assert note["title"] == "Buy milk"
    assert note["body"] == "2L"
    nid = note["id"]

    got = client.get(f"/notes/{nid}")
    assert got.status_code == 200
    assert got.json() == note


# TODO:
#   - blank/whitespace title -> 422
#   - GET missing id -> 404
#   - GET /notes lists all created notes
#   - DELETE -> 204, then GET that id -> 404 ; DELETE missing id -> 404
#   - enrich: mock api.requests (network is blocked!) and assert the word_count
#     comes from the mocked "count" field; enrich missing id -> 404
PYEOF
fi

echo
echo "Planted into: $WORK"
echo "  api.py       — the FastAPI service under test (read it; do NOT modify it)"
echo "  test_api.py  — write your tests here (client + reset fixtures provided)"
echo
echo "One-time setup:  cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest fastapi httpx requests"
echo "Iterate:         cd $WORK && .venv/bin/pytest -v"
echo "Verify + flag:   bash courses/course-36-python-testing/challenges/$SLUG/verify.sh"
