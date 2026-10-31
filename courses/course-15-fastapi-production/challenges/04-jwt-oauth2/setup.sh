#!/usr/bin/env bash
# Plants the "JWT OAuth2 — Bearer or 401" starter project.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/04-jwt-oauth2"
mkdir -p "$WORK/tests"

# ── main.py skeleton ─────────────────────────────────────────────────────────
cat > "$WORK/main.py" << 'PYEOF'
# main.py — OAuth2 + JWT skeleton
# Fill in the four stubbed sections. Constants, models, and route signatures
# are already declared — only the logic bodies are missing.
from datetime import datetime, timedelta, timezone
from typing import Annotated

import jwt
from fastapi import Depends, FastAPI, HTTPException, status
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from pydantic import BaseModel

SECRET_KEY = "dojo-super-secret-do-not-ship"
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 30

# Fake user DB — do not change the credentials; the verifier uses alice/secret.
_USERS = {
    "alice": {"username": "alice", "hashed_password": "secret"},
}

app = FastAPI()
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="token")


class Token(BaseModel):
    access_token: str
    token_type: str


class User(BaseModel):
    username: str


def create_access_token(data: dict, expires_delta: timedelta | None = None) -> str:
    # TODO: copy `data` into a `to_encode` dict.
    # Set the "exp" claim to utcnow() + (expires_delta or timedelta(minutes=15)).
    # Return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM).
    raise NotImplementedError


def authenticate_user(username: str, password: str) -> dict | None:
    # TODO: look up username in _USERS.
    # Return the user dict if found AND password matches hashed_password.
    # Return None otherwise.
    raise NotImplementedError


async def get_current_user(token: Annotated[str, Depends(oauth2_scheme)]) -> User:
    # TODO: decode the token with jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM]).
    # Catch jwt.InvalidTokenError and raise HTTPException(401, "Could not validate credentials",
    #   headers={"WWW-Authenticate": "Bearer"}).
    # Extract "sub" from the payload; raise 401 if missing.
    # Return User(username=sub).
    raise NotImplementedError


@app.post("/token", response_model=Token)
async def login(form_data: Annotated[OAuth2PasswordRequestForm, Depends()]):
    # TODO: call authenticate_user; raise HTTPException(401) on failure.
    # Call create_access_token with {"sub": user["username"]} and
    # expires_delta=timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES).
    # Return Token(access_token=..., token_type="bearer").
    raise NotImplementedError


@app.get("/me", response_model=User)
async def read_me(current_user: Annotated[User, Depends(get_current_user)]):
    return current_user
PYEOF

# ── tests/__init__.py ────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

# ── tests/test_sample.py — visible smoke test ────────────────────────────────
cat > "$WORK/tests/test_sample.py" << 'PYEOF'
# Visible sample test — run this locally to check the happy path.
# The verifier also runs a hidden suite with additional edge-case scenarios.
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_no_token_returns_401():
    r = client.get("/me")
    assert r.status_code == 401, f"expected 401 with no token, got {r.status_code}"


def test_login_and_access_me():
    r = client.post("/token", data={"username": "alice", "password": "secret"})
    assert r.status_code == 200, f"POST /token failed: {r.status_code} {r.text}"
    token = r.json()["access_token"]
    r2 = client.get("/me", headers={"Authorization": f"Bearer {token}"})
    assert r2.status_code == 200, f"GET /me with valid token failed: {r2.status_code}"
    assert r2.json()["username"] == "alice"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement the four TODO sections in main.py so the"
echo "                 verifier's hidden test suite (6 scenarios) passes."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install fastapi 'uvicorn[standard]' httpx pytest pydantic pyjwt"
echo
echo "Smoke test     : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag  : bash courses/course-15-fastapi-production/challenges/04-jwt-oauth2/verify.sh"
