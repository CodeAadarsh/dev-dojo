#!/usr/bin/env bash
# Plants the "Pydantic v2 Validator" starter project into the work directory.
# Idempotent — re-running overwrites source files but does not touch .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/02-pydantic-v2-validator"
mkdir -p "$WORK/tests"

# ── main.py skeleton ─────────────────────────────────────────────────────────
cat > "$WORK/main.py" << 'PYEOF'
# main.py — booking service skeleton
# Three gaps to fill:
#
# GAP 1: Add a validator on BookingCreate that rejects check_out <= check_in.
#        Use @field_validator('check_out', mode='after') or @model_validator(mode='after').
#        check_in must be declared before check_out so info.data contains it.
#
# GAP 2: Add a validator (or Field constraint) on BookingCreate that rejects
#        guests outside the range 1..10 inclusive.
#
# GAP 3: BookingResponse needs model_config = ConfigDict(from_attributes=True)
#        so model_validate(db_row) can read attributes off a plain Python object.
#
# GAP 4: Register an exception_handler for RequestValidationError on `app` that
#        returns HTTP 422 with:
#        {"status": 422, "error": "Validation Failed", "details": [str, ...]}
from datetime import date
from typing import Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="Booking Service")


class BookingCreate(BaseModel):
    room_number: int
    check_in: date       # GAP 1: check_in must come before check_out in the model
    check_out: date      # GAP 1: add validator here (or @model_validator below)
    guests: int          # GAP 2: add validator or Field(ge=1, le=10)
    notes: Optional[str] = None


class BookingDB:
    """Simulates a SQLAlchemy ORM row — attributes, not a dict."""
    def __init__(self, id: int, **kwargs):
        self.id = id
        for k, v in kwargs.items():
            setattr(self, k, v)


class BookingResponse(BaseModel):
    # GAP 3: add model_config = ConfigDict(from_attributes=True)
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
    return BookingResponse.model_validate(db_row)   # fails until GAP 3 is fixed


@app.get("/bookings/{booking_id}")
def get_booking(booking_id: int) -> BookingResponse:
    if booking_id not in _bookings:
        raise HTTPException(status_code=404, detail="booking not found")
    return BookingResponse.model_validate(_bookings[booking_id])  # fails until GAP 3 is fixed
PYEOF

# ── tests/test_bookings.py (visible harness) ──────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_bookings.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastapi.testclient import TestClient
from main import app

client = TestClient(app, raise_server_exceptions=False)

VALID = {
    "room_number": 101,
    "check_in": "2027-03-01",
    "check_out": "2027-03-05",
    "guests": 2,
}


def test_checkout_before_checkin_422():
    payload = {**VALID, "check_in": "2027-03-10", "check_out": "2027-03-05"}
    r = client.post("/bookings", json=payload)
    assert r.status_code == 422, (
        f"check_out before check_in must return 422, got {r.status_code}. "
        "Add a @field_validator or @model_validator to BookingCreate."
    )


def test_guests_zero_422():
    r = client.post("/bookings", json={**VALID, "guests": 0})
    assert r.status_code == 422, (
        f"guests=0 must return 422, got {r.status_code}. "
        "Add Field(ge=1) or a @field_validator on 'guests'."
    )


def test_guests_eleven_422():
    r = client.post("/bookings", json={**VALID, "guests": 11})
    assert r.status_code == 422, (
        f"guests=11 must return 422, got {r.status_code}. "
        "Add Field(le=10) or a @field_validator on 'guests'."
    )


def test_valid_booking_201():
    r = client.post("/bookings", json=VALID)
    assert r.status_code == 201, (
        f"valid booking must return 201, got {r.status_code}. "
        "If you get 500, BookingResponse is missing ConfigDict(from_attributes=True)."
    )
    assert "id" in r.json(), "response must include 'id'"


def test_get_booking_200():
    create = client.post("/bookings", json=VALID)
    assert create.status_code == 201
    bid = create.json()["id"]
    r = client.get(f"/bookings/{bid}")
    assert r.status_code == 200, (
        f"GET /bookings/{{id}} must return 200, got {r.status_code}. "
        "Check that BookingResponse has ConfigDict(from_attributes=True)."
    )
    assert r.json()["room_number"] == 101


def test_get_missing_404():
    r = client.get("/bookings/99999")
    assert r.status_code == 404


def test_error_envelope_shape():
    payload = {**VALID, "guests": 0}
    r = client.post("/bookings", json=payload)
    assert r.status_code == 422
    body = r.json()
    assert body.get("status") == 422, (
        f"error envelope must have 'status': 422, got: {body}. "
        "Register a RequestValidationError exception handler on app."
    )
    assert isinstance(body.get("details"), list), (
        f"error envelope must have 'details' as a list, got: {body}. "
        "Build 'details' from exc.errors() in the handler."
    )
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : fill the four gaps in main.py (see comments)"
echo "                 so all 7 tests in tests/test_bookings.py pass."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install fastapi 'uvicorn[standard]' httpx pytest pydantic sqlalchemy pyjwt"
echo
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-15-fastapi-production/challenges/02-pydantic-v2-validator/verify.sh"
