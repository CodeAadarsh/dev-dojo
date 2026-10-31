#!/usr/bin/env bash
# Verifier for "JWT OAuth2 — Bearer or 401".
# Runs a hidden pytest suite against the learner's main.py.
# Prints the flag only when all scenarios pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/04-jwt-oauth2"
FLAG='KUBE{bearer_token_or_401}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/main.py" ] || fail "main.py not found — run setup.sh first"

cd "$WORK"

if [ -d ".venv" ]; then
  source .venv/bin/activate
fi

python3 -c "import fastapi, jwt, pydantic" 2>/dev/null || \
  fail "dependencies missing — run: python3 -m venv .venv && . .venv/bin/activate && pip install fastapi 'uvicorn[standard]' httpx pytest pydantic pyjwt"

# ── hidden test suite ────────────────────────────────────────────────────────
HIDDEN_DIR="$(mktemp -d)"
trap 'rm -rf "$HIDDEN_DIR"' EXIT

cat > "$HIDDEN_DIR/test_hidden.py" << 'PYEOF'
import sys
import os
sys.path.insert(0, os.environ["WORK"])

import time
import jwt as pyjwt
from fastapi.testclient import TestClient
from main import app, SECRET_KEY, ALGORITHM

client = TestClient(app)


def _get_token(username="alice", password="secret"):
    r = client.post("/token", data={"username": username, "password": password})
    assert r.status_code == 200, f"login failed: {r.status_code} {r.text}"
    return r.json()["access_token"]


def test_no_bearer_returns_401():
    r = client.get("/me")
    assert r.status_code == 401, f"expected 401 with no token, got {r.status_code}"


def test_wrong_password_returns_401():
    r = client.post("/token", data={"username": "alice", "password": "wrong"})
    assert r.status_code == 401, f"expected 401 with wrong password, got {r.status_code}"


def test_valid_token_returns_200_with_username():
    token = _get_token()
    r = client.get("/me", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200, f"expected 200 with valid token, got {r.status_code}"
    assert r.json().get("username") == "alice", f"username mismatch: {r.json()}"


def test_token_response_shape():
    r = client.post("/token", data={"username": "alice", "password": "secret"})
    assert r.status_code == 200
    body = r.json()
    assert "access_token" in body, "missing access_token in token response"
    assert body.get("token_type", "").lower() == "bearer", "token_type must be 'bearer'"


def test_tampered_token_returns_401():
    token = _get_token()
    parts = token.split(".")
    # Flip the last character of the signature segment
    sig = parts[2]
    flipped = sig[:-1] + ("A" if sig[-1] != "A" else "B")
    tampered = ".".join([parts[0], parts[1], flipped])
    r = client.get("/me", headers={"Authorization": f"Bearer {tampered}"})
    assert r.status_code == 401, f"tampered token must return 401, got {r.status_code}"


def test_wrong_secret_token_returns_401():
    # Craft a valid-looking token signed with a different secret
    import datetime
    payload = {
        "sub": "alice",
        "exp": datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=30),
    }
    evil_token = pyjwt.encode(payload, "evil-secret", algorithm="HS256")
    r = client.get("/me", headers={"Authorization": f"Bearer {evil_token}"})
    assert r.status_code == 401, f"wrong-secret token must return 401, got {r.status_code}"
PYEOF

export WORK="$WORK"
if python3 -m pytest "$HIDDEN_DIR/test_hidden.py" -v 2>&1; then
    echo
    echo "All six auth scenarios passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "one or more hidden test scenarios failed — check your implementation and retry"
fi
