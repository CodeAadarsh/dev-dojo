#!/usr/bin/env bash
# Plants the "Async Auth Endpoints" challenge starter.
# Idempotent — re-running overwrites source files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/04-async-auth"
mkdir -p "$WORK/tests"

# ── main.py skeleton ────────────────────────────────────────────────────────
cat > "$WORK/main.py" << 'PYEOF'
# main.py — OAuth2 + JWT auth skeleton
# Implement the three endpoint bodies. The User schema, pwd_context,
# oauth2_scheme, and SECRET_KEY are already wired — only the logic
# inside each function is stubbed with a 501 placeholder.

from fastapi import FastAPI, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from pydantic import BaseModel
from datetime import datetime, timedelta, timezone
import jwt
from passlib.context import CryptContext

SECRET_KEY = "dojo-secret-change-in-prod"
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 30

app = FastAPI()
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/token")

# In-memory user store: { username: {"hashed_password": str, "email": str} }
_users_db: dict = {}


class UserCreate(BaseModel):
    username: str
    email: str
    password: str


class UserOut(BaseModel):
    username: str
    email: str


class Token(BaseModel):
    access_token: str
    token_type: str


@app.post("/auth/register", status_code=201, response_model=UserOut)
def register(user: UserCreate):
    # Hash user.password with pwd_context.hash().
    # If user.username already exists in _users_db, raise HTTP 409.
    # Store the hashed password and email in _users_db.
    # Return UserOut(username=..., email=...).
    raise HTTPException(status_code=501, detail="not implemented")


@app.post("/auth/token", response_model=Token)
def login(form: OAuth2PasswordRequestForm = Depends()):
    # Look up form.username in _users_db.
    # If not found, or pwd_context.verify(form.password, stored_hash) is False: raise HTTP 401
    #   with detail "Incorrect username or password" and header WWW-Authenticate: Bearer.
    # Create a JWT with {"sub": form.username, "exp": ..., "iat": ...} using HS256 + SECRET_KEY.
    # Return Token(access_token=..., token_type="bearer").
    raise HTTPException(status_code=501, detail="not implemented")


@app.get("/users/me", response_model=UserOut)
def get_current_user(token: str = Depends(oauth2_scheme)):
    # Decode the token using jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM]).
    # Catch jwt.ExpiredSignatureError -> raise HTTP 401 with detail "Token expired".
    # Catch jwt.InvalidTokenError -> raise HTTP 401 with detail "Could not validate credentials".
    # Extract the "sub" claim; if missing or empty, raise HTTP 401.
    # Look up the username in _users_db; if not found, raise HTTP 401.
    # Return UserOut(username=..., email=...).
    raise HTTPException(status_code=501, detail="not implemented")
PYEOF

# ── tests/__init__.py ────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

# ── tests/test_sample.py — visible sample test ───────────────────────────────
cat > "$WORK/tests/test_sample.py" << 'PYEOF'
# test_sample.py — one visible test to confirm your setup is working.
# The verifier runs additional hidden tests — don't rely on this alone.
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_register_returns_201():
    r = client.post("/auth/register", json={
        "username": "alice_sample",
        "email": "alice@example.com",
        "password": "hunter2"
    })
    assert r.status_code == 201, f"POST /auth/register must return 201, got {r.status_code}"
    body = r.json()
    assert body["username"] == "alice_sample"
    assert "password" not in body, "password must not appear in the response"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement the three endpoint bodies in main.py."
echo "                 tests/test_sample.py has one visible test."
echo "                 The verifier runs a broader hidden suite."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install fastapi 'uvicorn[standard]' httpx pytest pydantic pyjwt 'passlib[bcrypt]'"
echo
echo "Run sample test: cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag  : bash courses/course-15-fastapi-production/challenges/04-async-auth/verify.sh"
