# Validation and Error Envelopes

The on-call rotation fires at 2 AM. The React frontend is showing a raw Pydantic traceback to users because someone POSTed `{"name": "", "price": -5}`. Two separate failures: no field constraints on the model, and no custom error handler so the 422 detail leaks Pydantic internals. A 404 hit on `/items/9999` returns HTML (FastAPI's default) because the client is calling from a mobile app that expects JSON.

Your job: add constraints to the Pydantic model and register two exception handlers that produce a consistent JSON envelope for every error the API can emit.

## Context

`setup.sh` plants the starter:

```
~/.kube-dojo-work/02-validation-and-errors/
├── main.py          # FastAPI app with working CRUD but no constraints + no custom handlers
└── tests/
    └── test_sample.py   # visible warm-up test
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/02-validation-and-errors
python3 -m venv .venv && . .venv/bin/activate
pip install fastapi "uvicorn[standard]" httpx pytest pydantic
```

## Mission

Edit `main.py` to:

1. **Add field constraints to `ItemCreate`:**
   - `name`: non-empty string, max 120 characters
   - `price`: must be greater than 0

2. **Register a custom `RequestValidationError` handler** that returns:
   ```json
   {"status": 422, "error": "Unprocessable Entity", "details": [...]}
   ```
   where `details` is a list of objects derived from the Pydantic error list.

3. **Register a custom `StarletteHTTPException` handler** for 404 that returns:
   ```json
   {"status": 404, "error": "Not Found", "message": "<path> not found"}
   ```

The hidden harness asserts:

| Check | Expected |
|-------|----------|
| `POST /items` with `name=""` | 422 |
| `POST /items` with `price=-1` | 422 |
| `POST /items` with `name` > 120 chars | 422 |
| 422 response `Content-Type` | `application/json` |
| 422 body shape | `{"status":422,"error":"Unprocessable Entity","details":[...]}` |
| `GET /items/999999` | 404 |
| 404 response `Content-Type` | `application/json` |
| 404 body shape | `{"status":404,"error":"Not Found","message":"..."}` |
| `POST /items` valid body | 201, item returned |

## Why envelope consistency matters

Without a consistent envelope, every API consumer needs its own error-parsing logic. A `{"detail": [...]}` from FastAPI's default 422 handler is structurally incompatible with a `{"message": "..."}` from your 404 handler. A mobile client, an integration test, and a monitoring alert all need to handle the same three shapes instead of one. Define the envelope once, register handlers once, reference it everywhere.

## Verify

```bash
bash courses/course-15-fastapi-production/challenges/02-validation-and-errors/verify.sh
```

All tests green → flag printed.
