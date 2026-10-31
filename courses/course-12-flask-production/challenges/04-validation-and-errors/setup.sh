#!/usr/bin/env bash
# Plants the "Validate or Regret It" challenge: a Flask app skeleton that needs
# input validation and consistent JSON error responses.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/04-validation-and-errors"

mkdir -p "$WORK/tests"

# ── app.py skeleton ───────────────────────────────────────────────────────────
cat > "$WORK/app.py" << 'PYEOF'
from flask import Flask, jsonify, request


def create_app():
    app = Flask(__name__)

    @app.route('/users', methods=['POST'])
    def create_user():
        data = request.get_json(silent=True) or {}

        # TODO: validate that:
        #   - 'name'  is present and a non-empty string
        #   - 'age'   is present, an integer, and in the range 1-120
        #
        # On any validation failure return HTTP 422 with this JSON envelope:
        #   {
        #     "status": 422,
        #     "error": "Unprocessable Entity",
        #     "details": ["<human-readable problem>", ...]
        #   }
        #
        # Hint: collect all errors into a list so you return them all at once,
        # not just the first one you encounter.

        return jsonify({'id': 1, 'name': data.get('name'), 'age': data.get('age')}), 201

    # TODO: register a 404 error handler on `app` using @app.errorhandler(404).
    # It must return a JSON response (application/json) with HTTP 404 and body:
    #   {
    #     "status": 404,
    #     "error": "Not Found",
    #     "message": "<request.path> not found"
    #   }

    return app
PYEOF

# ── requirements.txt ──────────────────────────────────────────────────────────
cat > "$WORK/requirements.txt" << 'EOF'
flask==3.1.1
pytest==8.3.5
EOF

# ── test harness (DO NOT EDIT) ────────────────────────────────────────────────
cat > "$WORK/tests/test_harness.py" << 'PYEOF'
# DO NOT EDIT — this file is run by verify.sh
import pytest
from app import create_app


@pytest.fixture
def client():
    app = create_app()
    app.config['TESTING'] = True
    with app.test_client() as c:
        yield c


def test_missing_name_returns_422(client):
    rv = client.post('/users', json={'age': 25})
    assert rv.status_code == 422, f"expected 422, got {rv.status_code}"


def test_missing_age_returns_422(client):
    rv = client.post('/users', json={'name': 'Alice'})
    assert rv.status_code == 422, f"expected 422, got {rv.status_code}"


def test_invalid_age_string_returns_422(client):
    rv = client.post('/users', json={'name': 'Alice', 'age': 'old'})
    assert rv.status_code == 422, f"expected 422, got {rv.status_code}"


def test_age_out_of_range_returns_422(client):
    rv = client.post('/users', json={'name': 'Alice', 'age': 200})
    assert rv.status_code == 422, f"expected 422, got {rv.status_code}"


def test_422_body_is_json_envelope(client):
    rv = client.post('/users', json={'age': 25})
    assert rv.content_type.startswith('application/json'), \
        f"expected application/json, got {rv.content_type}"
    body = rv.get_json()
    assert body is not None, "response body is not valid JSON"
    assert body.get('status') == 422, f"envelope 'status' must be 422, got {body.get('status')}"
    assert 'error' in body, "envelope missing 'error' key"
    assert 'details' in body or 'message' in body, \
        "envelope must have 'details' (list) or 'message' key"


def test_valid_user_returns_201(client):
    rv = client.post('/users', json={'name': 'Alice', 'age': 30})
    assert rv.status_code == 201, f"expected 201, got {rv.status_code}"
    body = rv.get_json()
    assert body is not None
    assert body.get('name') == 'Alice'


def test_unknown_route_returns_404_json(client):
    rv = client.get('/does-not-exist')
    assert rv.status_code == 404, f"expected 404, got {rv.status_code}"
    assert rv.content_type.startswith('application/json'), \
        f"404 response must be application/json, got {rv.content_type}"


def test_404_body_is_json_envelope(client):
    rv = client.get('/does-not-exist')
    body = rv.get_json()
    assert body is not None, "404 response body is not valid JSON"
    assert body.get('status') == 404, f"envelope 'status' must be 404, got {body.get('status')}"
    assert 'error' in body, "404 envelope missing 'error' key"
PYEOF

echo
echo "Work directory: $WORK"
echo
echo "Task: edit app.py — add input validation to POST /users and a 404 error handler."
echo "The test harness at tests/test_harness.py must pass without modification."
echo
echo "Prereqs (run inside $WORK):"
echo "  python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt"
echo
echo "Run the verifier when ready:"
echo "  bash courses/course-12-flask-production/challenges/04-validation-and-errors/verify.sh"
