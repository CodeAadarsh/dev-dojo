# Pagination & Status Codes

A ticket lands in your queue: *"The /items endpoint is crashing client SDKs. They expect 201 on create, 204 on delete, and pagination — but the service returns 200 everywhere, blows up with 500 on missing IDs, and dumps the entire catalogue on every GET."*

You open the code. Basic CRUD works, but three classes of bugs are baked in:

1. **Wrong status codes** — `POST` returns 200 (not 201), `DELETE` crashes instead of 204.
2. **No 404 handling** — `GET/PUT/DELETE` on a missing ID hits an unguarded `KeyError` and returns 500.
3. **No pagination** — `GET /items` ignores `?limit=` and `?offset=` and always returns everything.

## Context

`setup.sh` plants the broken implementation and the harness in:

```
~/.kube-dojo-work/02-pagination-and-status-codes/
├── main.py          # working CRUD with three classes of bugs (comments mark them)
└── tests/
    └── test_api.py  # nine-test harness you must make pass
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/02-pagination-and-status-codes
python3 -m venv .venv && . .venv/bin/activate
pip install fastapi pytest httpx
```

## Mission

Fix `main.py` so all nine tests pass. The exact conditions the harness checks:

| Test | What it verifies |
|------|-----------------|
| `test_post_returns_201` | `POST /items` → 201 |
| `test_post_invalid_body_returns_422` | `POST /items` with missing `price` → 422 |
| `test_list_default_returns_200` | `GET /items` → 200, list |
| `test_pagination_limit` | `GET /items?limit=3` → at most 3 items |
| `test_pagination_offset` | `GET /items?limit=3&offset=3` → different items from `offset=0` |
| `test_get_missing_returns_404` | `GET /items/999999` → 404 |
| `test_put_missing_returns_404` | `PUT /items/999999` → 404 |
| `test_delete_returns_204` | `DELETE /items/{id}` → 204 |
| `test_delete_missing_returns_404` | `DELETE /items/999999` → 404 |

## Pagination contract

Standard cursor-free pagination. `limit` caps the page size; `offset` skips that many items from the beginning of the ordered list. Both default to something sane (e.g. `limit=100, offset=0`). Both must accept `ge=0`.

`GET /items?limit=3&offset=0` → first 3 items.
`GET /items?limit=3&offset=3` → items 4–6.

In FastAPI this is a two-line addition using `Query` from `fastapi`.

## Why 422 instead of 400

FastAPI validates request bodies via Pydantic before your handler runs. When a required field is missing, Pydantic raises a `RequestValidationError` that FastAPI automatically converts to a 422 Unprocessable Entity. You do not have to write this validation — you get it for free if your model declares `price: float` as non-optional. The test verifies you haven't broken that behaviour.

## Verify

```bash
bash courses/course-10-backend-engineering/challenges/02-pagination-and-status-codes/verify.sh
```
