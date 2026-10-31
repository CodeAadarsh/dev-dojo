# Build a REST API

The backend team shipped a new service with only the routing registered — no logic. A pull request comment reads: *"The harness is green on CI because every test is `xfail`. Please implement the endpoints before we merge."*

Your job: fill in `main.py` so the real pytest harness passes end-to-end.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/01-build-a-rest-api/
├── main.py          # FastAPI app — models and routes defined, bodies are stubs
└── tests/
    └── test_api.py  # nine-test harness; your implementation must pass all of them
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/01-build-a-rest-api
python3 -m venv .venv && . .venv/bin/activate
pip install fastapi pytest httpx
```

## Mission

Implement the five endpoint bodies in `main.py`. The Pydantic models and the in-memory store skeleton (`_store: dict`, `_next_id: int`) are already declared — only the logic inside each function is stubbed.

The harness asserts exact HTTP semantics:

| Endpoint | Method | Required status |
|----------|--------|-----------------|
| `POST /items` | create | **201** Created |
| `GET /items` | list all | **200** OK |
| `GET /items/{id}` | get one | **200** OK |
| `GET /items/{id}` (missing) | get one | **404** Not Found |
| `PUT /items/{id}` | replace | **200** OK |
| `PUT /items/{id}` (missing) | replace | **404** Not Found |
| `DELETE /items/{id}` | remove | **204** No Content |
| `DELETE /items/{id}` (missing) | remove | **404** Not Found |

Status codes are not optional — a 200 where a 204 is required is a test failure.

## Why the status codes matter

`201` tells the client a resource was created and its URI is in `Location`.
`204` tells the client the operation succeeded and there is nothing to render — a response body on a 204 is wrong.
`404` vs a crash (unhandled `KeyError`) is the difference between a well-behaved service and one that exposes internal state via 500 stack traces.

Getting these right at the framework level (`status_code=` in the decorator, `HTTPException(status_code=404)` in the body) is the habit that separates clean APIs from ones that clients can't rely on.

## Verify

```bash
bash courses/course-10-backend-engineering/challenges/01-build-a-rest-api/verify.sh
```

All nine tests green → flag printed.
