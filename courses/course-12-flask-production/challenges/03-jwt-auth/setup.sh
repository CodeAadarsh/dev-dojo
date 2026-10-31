#!/usr/bin/env bash
# Plants the "JWT Login and Protected Routes" challenge skeleton.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/03-jwt-auth"
mkdir -p "$WORK/tests"

# ── app.py skeleton ──────────────────────────────────────────────────────────
cat > "$WORK/app.py" << 'PYEOF'
from flask import Flask, jsonify, request
import jwt
import datetime

# Hardcoded user store for this challenge — one valid credential pair.
_USERS = {'admin': 'secret'}


def create_app(test_config=None):
    app = Flask(__name__)
    app.config['SECRET_KEY'] = 'dev-secret-change-in-production'
    if test_config:
        app.config.update(test_config)

    @app.route('/login', methods=['POST'])
    def login():
        # 1. Parse JSON body: {"username": "...", "password": "..."}.
        # 2. Look up the username in _USERS; compare the password.
        # 3. On mismatch, return 401.
        # 4. On match, sign a JWT with app.config['SECRET_KEY'] (algorithm HS256).
        #    Include at least: sub (username), exp (now + 1 hour).
        # 5. Return {"token": "<signed jwt>"} with 200.
        return jsonify({'error': 'not implemented'}), 501

    @app.route('/protected')
    def protected():
        # 1. Extract the Bearer token from the Authorization header.
        # 2. If the header is missing or not "Bearer <token>", return 401.
        # 3. Decode and VERIFY the token with app.config['SECRET_KEY'].
        #    Use algorithms=['HS256']. Catch jwt.PyJWTError for any failure.
        # 4. On verification failure (bad sig, expired, malformed), return 401.
        # 5. On success, return any JSON body with 200.
        return jsonify({'error': 'not implemented'}), 501

    return app
PYEOF

# ── tests/__init__.py ────────────────────────────────────────────────────────
touch "$WORK/tests/__init__.py"

# ── tests/test_harness.py (DO NOT EDIT) ─────────────────────────────────────
cat > "$WORK/tests/test_harness.py" << 'PYEOF'
# DO NOT EDIT — this file is run by verify.sh
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import datetime
import jwt as pyjwt
import pytest
from app import create_app

SECRET = 'test-secret-key-for-harness'


@pytest.fixture
def client():
    app = create_app({'TESTING': True, 'SECRET_KEY': SECRET})
    with app.test_client() as c:
        yield c


def test_login_valid_credentials_returns_token(client):
    rv = client.post('/login', json={'username': 'admin', 'password': 'secret'})
    assert rv.status_code == 200, f"POST /login must return 200 for valid creds, got {rv.status_code}"
    data = rv.get_json()
    assert data is not None, "POST /login must return a JSON body"
    assert 'token' in data, f"response must contain 'token' key, got {data}"


def test_login_wrong_password_returns_401(client):
    rv = client.post('/login', json={'username': 'admin', 'password': 'wrong'})
    assert rv.status_code == 401, f"wrong password must return 401, got {rv.status_code}"


def test_protected_missing_header_returns_401(client):
    rv = client.get('/protected')
    assert rv.status_code == 401, f"missing Authorization header must return 401, got {rv.status_code}"


def test_protected_with_valid_token_returns_200(client):
    login = client.post('/login', json={'username': 'admin', 'password': 'secret'})
    assert login.status_code == 200, "login precondition failed"
    token = login.get_json()['token']
    rv = client.get('/protected', headers={'Authorization': f'Bearer {token}'})
    assert rv.status_code == 200, f"valid token must return 200, got {rv.status_code}"


def test_protected_with_invalid_token_returns_401(client):
    rv = client.get('/protected', headers={'Authorization': 'Bearer not.a.real.jwt'})
    assert rv.status_code == 401, f"malformed token must return 401, got {rv.status_code}"


def test_protected_with_token_signed_by_wrong_key_returns_401(client):
    forged = pyjwt.encode(
        {
            'sub': 'admin',
            'exp': datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=1),
        },
        'attacker-controlled-secret',
        algorithm='HS256',
    )
    rv = client.get('/protected', headers={'Authorization': f'Bearer {forged}'})
    assert rv.status_code == 401, (
        f"token signed with wrong key must return 401, got {rv.status_code}. "
        "Did you verify the signature with app.config['SECRET_KEY']?"
    )
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement /login and /protected in app.py so all harness"
echo "                 tests pass — including rejection of tokens signed with"
echo "                 a different key."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install flask pytest pyjwt"
echo
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-12-flask-production/challenges/03-jwt-auth/verify.sh"
