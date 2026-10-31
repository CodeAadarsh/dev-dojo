# Solution — Pydantic v2 Validator

Four targeted additions to `main.py`.

```python
# main.py — booking service, fully validated
from datetime import date
from typing import Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

app = FastAPI(title="Booking Service")


# GAP 4: custom 422 envelope
@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
    return JSONResponse(
        status_code=422,
        content={
            "status": 422,
            "error": "Validation Failed",
            "details": [e["msg"] for e in exc.errors()],
        },
    )


class BookingCreate(BaseModel):
    room_number: int
    check_in: date
    check_out: date
    guests: int = Field(ge=1, le=10)     # GAP 2: range constraint

    notes: Optional[str] = None

    # GAP 1: cross-field — check_out must be after check_in
    @model_validator(mode='after')
    def check_out_after_check_in(self) -> 'BookingCreate':
        if self.check_out <= self.check_in:
            raise ValueError('check_out must be strictly after check_in')
        return self


class BookingDB:
    """Simulates a SQLAlchemy ORM row — attributes, not a dict."""
    def __init__(self, id: int, **kwargs):
        self.id = id
        for k, v in kwargs.items():
            setattr(self, k, v)


class BookingResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)   # GAP 3: ORM mode

    id: int
    room_number: int
    check_in: date
    check_out: date
    guests: int
    notes: Optional[str] = None


_bookings: dict = {}
_next_id: int = 1


@app.post("/bookings", status_code=201)
def create_booking(booking: BookingCreate) -> BookingResponse:
    global _next_id
    db_row = BookingDB(_next_id, **booking.model_dump())
    _bookings[_next_id] = db_row
    _next_id += 1
    return BookingResponse.model_validate(db_row)


@app.get("/bookings/{booking_id}")
def get_booking(booking_id: int) -> BookingResponse:
    if booking_id not in _bookings:
        raise HTTPException(status_code=404, detail="booking not found")
    return BookingResponse.model_validate(_bookings[booking_id])
```

## Why each piece matters

**GAP 1: `@model_validator(mode='after')` for cross-field validation.**
`@field_validator('check_out')` also works, but `@model_validator(mode='after')` is cleaner for invariants that span multiple fields because `self` is a fully-constructed instance — no `info.data` indexing required. Either approach: **declare `check_in` before `check_out`** in the model body. Pydantic validates fields in declaration order; if `check_in` is declared after, it is absent from `info.data` when `check_out` is validated.

**GAP 2: `Field(ge=1, le=10)`.**
An annotated constraint is the lowest-friction option — it compiles into the OpenAPI schema (clients see the allowed range in docs) and is enforced before any validator runs. A `@field_validator` achieves the same result but adds a function when a metadata annotation is enough.

**GAP 3: `ConfigDict(from_attributes=True)`.**
Without it, `BookingResponse.model_validate(db_row)` fails with `ValidationError: Input should be a valid dictionary` because Pydantic treats `db_row` as a dict and calls `db_row["id"]`, which raises `TypeError`. With `from_attributes=True`, Pydantic reads `db_row.id`, `db_row.room_number`, etc. — attribute access, not dict access.

**GAP 4: `RequestValidationError` handler.**
FastAPI's built-in 422 body is `{"detail": [...]}`. That's fine for development but inconsistent with any custom error shape you use elsewhere. The handler intercepts all Pydantic validation failures and rewrites the body to your chosen envelope. Register it *before* any route, or as early as possible in `main.py`, so it applies to all routes including those from included routers.

## Hardening preview

In production, add a catch-all:

```python
@app.exception_handler(Exception)
async def unhandled(request: Request, exc: Exception) -> JSONResponse:
    import logging
    logging.exception("unhandled error %s %s", request.method, request.url.path)
    return JSONResponse(status_code=500, content={"status": 500, "error": "Internal Server Error"})
```

Never let a raw Python exception reach the client — it exposes import paths, class names, and internal state in the traceback that Starlette defaults to including in 500 responses in debug mode.
