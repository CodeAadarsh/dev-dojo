#!/usr/bin/env bash
# Plants the "App Factory" challenge skeleton.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/01-app-factory"
mkdir -p "$WORK/app" "$WORK/tests"

# ── app/__init__.py skeleton ─────────────────────────────────────────────────
cat > "$WORK/app/__init__.py" << 'PYEOF'
from flask import Flask


def create_app():
    # 1. Construct a Flask app instance.
    # 2. Import and register the 'main' Blueprint from app.views.
    # 3. Return the app — do NOT assign app at module scope.
    raise NotImplementedError("implement create_app()")
PYEOF

# ── app/views.py skeleton ────────────────────────────────────────────────────
cat > "$WORK/app/views.py" << 'PYEOF'
from flask import Blueprint, jsonify

main = Blueprint('main', __name__)


@main.route('/health')
def health():
    # Return JSON {"status": "ok"} with HTTP 200.
    raise NotImplementedError("implement /health")


@main.route('/version')
def version():
    # Return JSON {"version": "<any string>"} with HTTP 200.
    raise NotImplementedError("implement /version")
PYEOF

# ── tests/__init__.py ────────────────────────────────────────────────────────
touch "$WORK/tests/__init__.py"

# ── tests/test_harness.py (DO NOT EDIT) ─────────────────────────────────────
cat > "$WORK/tests/test_harness.py" << 'PYEOF'
# DO NOT EDIT — this file is run by verify.sh
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest
from app import create_app


@pytest.fixture
def client():
    app = create_app()
    app.config['TESTING'] = True
    with app.test_client() as c:
        yield c


def test_health_returns_200(client):
    rv = client.get('/health')
    assert rv.status_code == 200, f"GET /health must return 200, got {rv.status_code}"


def test_health_body_is_status_ok(client):
    rv = client.get('/health')
    body = rv.get_json()
    assert body is not None, "GET /health must return a JSON body"
    assert body == {'status': 'ok'}, f"body must be {{'status':'ok'}}, got {body}"


def test_version_returns_200(client):
    rv = client.get('/version')
    assert rv.status_code == 200, f"GET /version must return 200, got {rv.status_code}"


def test_version_body_has_version_key(client):
    rv = client.get('/version')
    body = rv.get_json()
    assert body is not None, "GET /version must return a JSON body"
    assert 'version' in body, f"response must contain 'version' key, got {body}"


def test_health_served_by_blueprint(client):
    rules = {rule.rule: rule.endpoint for rule in client.application.url_map.iter_rules()}
    endpoint = rules.get('/health', '')
    assert '.' in endpoint, (
        f"/health must be on a Blueprint (endpoint='{endpoint}' has no '.'); "
        "register it via app.register_blueprint()"
    )


def test_create_app_returns_fresh_instance():
    from app import create_app as factory
    a1 = factory()
    a2 = factory()
    assert a1 is not a2, "create_app() must return a new Flask instance on each call"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement create_app() in app/__init__.py and the route"
echo "                 handlers in app/views.py so all harness tests pass."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install flask pytest"
echo
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-12-flask-production/challenges/01-app-factory/verify.sh"
