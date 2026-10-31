# Pydantic v2 Validator

A booking service was written "type-safely" but the PR reviewer pushed back: *"Pydantic types are there but no validators. I can book a room where checkout is before check-in, guests=0 passes, and the ORM response blows up with a ValidationError. Fix all three."*

Your job: add the missing validators and ORM mode to `main.py` so the seven-test harness passes.

## Context

`setup.sh` plants the starter in your work directory:

```
~/.kube-dojo-work/02-pydantic-v2-validator/
├── main.py          # FastAPI booking service — models exist, validators missing
└── tests/
    └── test_bookings.py   # seven-test harness; your fix must pass all of them
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/02-pydantic-v2-validator
python3 -m venv .venv && . .venv/bin/activate
pip install fastapi "uvicorn[standard]" httpx pytest pydantic sqlalchemy pyjwt
```

## Mission

Three gaps to fill in `main.py`:

### 1 — Cross-field validator: `check_out` must be after `check_in`

Add a `@field_validator('check_out', mode='after')` (or `@model_validator(mode='after')`) to `BookingCreate` that raises `ValueError` when `check_out <= check_in`. **`check_in` must be declared before `check_out`** in the model for `info.data` to contain it.

### 2 — Guests constraint

Add a `@field_validator('guests', mode='after')` that rejects guests outside the range `1..10` (inclusive). A `Field(ge=1, le=10)` annotation also works.

### 3 — ORM mode on `BookingResponse`

`BookingResponse.model_validate(db_row)` receives a plain Python object with attributes, not a dict. Without `model_config = ConfigDict(from_attributes=True)`, Pydantic raises `ValidationError` and every GET returns 500. Add the config.

### 4 — Custom `RequestValidationError` handler

Register an exception handler on `app` for `RequestValidationError` that returns HTTP 422 with this envelope:

```json
{
  "status": 422,
  "error": "Validation Failed",
  "details": ["<message 1>", "<message 2>"]
}
```

The test checks that `status` is `422` and `"details"` is a list. The exact strings inside `details` are not asserted.

## The harness asserts

| Test | Requirement |
|------|-------------|
| `test_checkout_before_checkin_422` | check_out ≤ check_in → 422 |
| `test_guests_zero_422` | guests=0 → 422 |
| `test_guests_eleven_422` | guests=11 → 422 |
| `test_valid_booking_201` | valid payload → 201 with `id` in response |
| `test_get_booking_200` | GET /bookings/{id} → 200 with ORM-sourced data |
| `test_get_missing_404` | GET /bookings/99999 → 404 |
| `test_error_envelope_shape` | 422 body has `status: 422` and `details` list |

## Why this matters

The database stores whatever you commit. A cross-field validator is the one place guaranteed to run before any data touches the store — the ORM has no concept of "checkout after checkin". Getting validation wrong at the model layer means the bug lives in the DB forever.

## Verify

```bash
bash courses/course-15-fastapi-production/challenges/02-pydantic-v2-validator/verify.sh
```

All seven tests green → flag printed.
