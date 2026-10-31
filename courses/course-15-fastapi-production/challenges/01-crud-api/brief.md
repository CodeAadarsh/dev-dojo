# CRUD API with Status Codes

A new service is under code review. The PR description says: *"Routes are registered, models defined, bodies stubbed — harness is xfail across the board. Need working implementations before merge."*

Your job: fill in the five endpoint bodies so every test in the hidden pytest harness goes green.

## Context

`setup.sh` plants the starter project:

```
~/.kube-dojo-work/01-crud-api/
├── main.py          # FastAPI app — Pydantic models + route stubs
└── tests/
    └── test_sample.py   # one visible warm-up test (not the real harness)
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/01-crud-api
python3 -m venv .venv && . .venv/bin/activate
pip install fastapi "uvicorn[standard]" httpx pytest pydantic
```

## Mission

Implement the five endpoint bodies in `main.py`. The Pydantic models and the in-memory store (`_store: dict`, `_next_id: int`) are declared — only the logic inside each route function is stubbed with a 501 placeholder.

The hidden harness asserts exact HTTP semantics:

| Endpoint | Method | Required status |
|----------|--------|-----------------|
| `POST /items` | create | **201** Created |
| `GET /items` | list all | **200** OK, returns list |
| `GET /items/{id}` | get one | **200** OK |
| `GET /items/{id}` (missing) | 404 | **404** Not Found |
| `PUT /items/{id}` | replace | **200** OK |
| `PUT /items/{id}` (missing) | 404 | **404** Not Found |
| `DELETE /items/{id}` | remove | **204** No Content |
| `DELETE /items/{id}` (missing) | 404 | **404** Not Found |

Status codes are not optional. A `200` where `204` is required is a test failure. A `500` (from an unhandled `KeyError`) where `404` is required is a test failure.

## Why the status codes matter

`201` signals the client that a *new* resource was created (distinct from 200, which means "ok, here's data that already existed"). Some clients use this to decide whether to update a cache entry vs insert a new one.

`204` signals "success, nothing to render." A body on a 204 is a protocol violation — don't return `{}` or `{"ok": True}`.

`404` vs `500` on a missing key is the difference between a client that can handle "not found" gracefully and one that shows your Python traceback to an end user.

## Verify

```bash
bash courses/course-15-fastapi-production/challenges/01-crud-api/verify.sh
```

All tests green → flag printed.
