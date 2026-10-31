#!/usr/bin/env bash
# Verifier for "Async Auth Endpoints".
# Writes a hidden pytest suite to a temp dir, runs it against the learner's main.py,
# and prints the flag only when all tests pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/04-async-auth"
FLAG='KUBE{async_session_per_request_not_global}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/main.py" ] || fail "main.py not found in $WORK — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
    PYTHON=".venv/bin/python3"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
    PYTHON="python3"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install fastapi httpx pytest pydantic pyjwt 'passlib[bcrypt]'"
fi

TMPDIR_SUITE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SUITE"' EXIT

cat > "$TMPDIR_SUITE/test_auth_hidden.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.environ["WORK_DIR"])

import pytest
from fastapi.testclient import TestClient

def fresh_app():
    import importlib, types
    # reload main to get a clean _users_db for each test
    import main as m
    m._users_db.clear()
    return TestClient(m.app)


def test_register_returns_201():
    client = fresh_app()
    r = client.post("/auth/register", json={"username": "alice", "email": "a@x.com", "password": "pw1"})
    assert r.status_code == 201, f"POST /auth/register must return 201, got {r.status_code}"
    body = r.json()
    assert body.get("username") == "alice"
    assert body.get("email") == "a@x.com"
    assert "password" not in body, "hashed or plaintext password must not appear in response"


def test_register_duplicate_returns_409():
    client = fresh_app()
    client.post("/auth/register", json={"username": "bob", "email": "b@x.com", "password": "pw"})
    r = client.post("/auth/register", json={"username": "bob", "email": "b2@x.com", "password": "pw"})
    assert r.status_code == 409, f"duplicate username must return 409, got {r.status_code}"


def test_login_returns_token():
    client = fresh_app()
    client.post("/auth/register", json={"username": "carol", "email": "c@x.com", "password": "secret99"})
    r = client.post("/auth/token", data={"username": "carol", "password": "secret99"})
    assert r.status_code == 200, f"login must return 200, got {r.status_code}"
    body = r.json()
    assert "access_token" in body, "response must contain access_token"
    assert body.get("token_type") == "bearer", "token_type must be 'bearer'"
    assert isinstance(body["access_token"], str) and len(body["access_token"]) > 20


def test_login_wrong_password_returns_401():
    client = fresh_app()
    client.post("/auth/register", json={"username": "dave", "email": "d@x.com", "password": "correct"})
    r = client.post("/auth/token", data={"username": "dave", "password": "wrong"})
    assert r.status_code == 401, f"wrong password must return 401, got {r.status_code}"


def test_login_unknown_user_returns_401():
    client = fresh_app()
    r = client.post("/auth/token", data={"username": "nobody", "password": "pw"})
    assert r.status_code == 401, f"unknown user must return 401, got {r.status_code}"


def test_me_with_valid_token_returns_user():
    client = fresh_app()
    client.post("/auth/register", json={"username": "eve", "email": "e@x.com", "password": "pw2"})
    tok = client.post("/auth/token", data={"username": "eve", "password": "pw2"}).json()["access_token"]
    r = client.get("/users/me", headers={"Authorization": f"Bearer {tok}"})
    assert r.status_code == 200, f"valid token must return 200, got {r.status_code}"
    body = r.json()
    assert body.get("username") == "eve"
    assert body.get("email") == "e@x.com"


def test_me_without_token_returns_401():
    client = fresh_app()
    r = client.get("/users/me")
    assert r.status_code == 401, f"missing token must return 401, got {r.status_code}"


def test_me_with_tampered_token_returns_401():
    client = fresh_app()
    client.post("/auth/register", json={"username": "frank", "email": "f@x.com", "password": "pw3"})
    tok = client.post("/auth/token", data={"username": "frank", "password": "pw3"}).json()["access_token"]
    # flip the last character of the signature segment
    parts = tok.split(".")
    tampered = parts[0] + "." + parts[1] + "." + parts[2][:-1] + ("A" if parts[2][-1] != "A" else "B")
    r = client.get("/users/me", headers={"Authorization": f"Bearer {tampered}"})
    assert r.status_code == 401, f"tampered token must return 401, got {r.status_code}"


def test_password_is_hashed_not_plaintext():
    import main as m
    m._users_db.clear()
    client = TestClient(m.app)
    client.post("/auth/register", json={"username": "grace", "email": "g@x.com", "password": "mypassword"})
    stored = m._users_db.get("grace", {})
    hp = stored.get("hashed_password", stored.get("password", ""))
    assert hp != "mypassword", "password must be stored hashed, not plaintext"
    assert len(hp) > 20, "stored value does not look like a bcrypt hash"
PYEOF

if WORK_DIR="$WORK" $PYTEST "$TMPDIR_SUITE/test_auth_hidden.py" -q 2>&1; then
    echo
    echo "All auth tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix your implementation and retry"
fi
