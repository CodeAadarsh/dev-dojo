#!/usr/bin/env bash
# Plants the "Test the App You Didn't Write" challenge.
# Provides a complete working Flask app and an empty/failing test file.
# Idempotent — re-running overwrites files.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/05-pytest-suite"
mkdir -p "$WORK/tests"

# ── app.py (complete, working — do not edit) ──────────────────────────────────
cat > "$WORK/app.py" << 'PYEOF'
# app.py — a small task-tracker API.
# Read this file to understand the contracts; write tests in tests/test_app.py.
from flask import Flask, jsonify, request

_tasks = {}
_next_id = 1


def create_app():
    app = Flask(__name__)

    @app.route('/health')
    def health():
        return jsonify({'status': 'ok'}), 200

    @app.route('/tasks', methods=['POST'])
    def create_task():
        global _next_id
        data = request.get_json(silent=True) or {}
        title = data.get('title', '').strip()
        if not title:
            return jsonify({'status': 422, 'error': 'title is required'}), 422
        task = {'id': _next_id, 'title': title, 'done': False}
        _tasks[_next_id] = task
        _next_id += 1
        return jsonify(task), 201

    @app.route('/tasks/<int:task_id>')
    def get_task(task_id):
        task = _tasks.get(task_id)
        if task is None:
            return jsonify({'status': 404, 'error': 'not found'}), 404
        return jsonify(task), 200

    return app
PYEOF

# ── requirements.txt ─────────────────────────────────────────────────────────
cat > "$WORK/requirements.txt" << 'EOF'
flask==3.1.1
pytest==8.3.5
EOF

# ── tests/__init__.py ────────────────────────────────────────────────────────
touch "$WORK/tests/__init__.py"

# ── tests/test_app.py skeleton (learner must complete) ───────────────────────
cat > "$WORK/tests/test_app.py" << 'PYEOF'
# tests/test_app.py
# Write the six required test functions below.
# Each function name must match the verifier's checklist EXACTLY.
import pytest
from app import create_app


@pytest.fixture
def client():
    app = create_app()
    app.config['TESTING'] = True
    with app.test_client() as c:
        yield c


# Required: test_health_returns_200
def test_health_returns_200(client):
    raise NotImplementedError("write this test")


# Required: test_health_body
def test_health_body(client):
    raise NotImplementedError("write this test")


# Required: test_create_task_returns_201
def test_create_task_returns_201(client):
    raise NotImplementedError("write this test")


# Required: test_create_task_has_id
def test_create_task_has_id(client):
    raise NotImplementedError("write this test")


# Required: test_get_task_returns_200
def test_get_task_returns_200(client):
    raise NotImplementedError("write this test")


# Required: test_get_missing_task_returns_404
def test_get_missing_task_returns_404(client):
    raise NotImplementedError("write this test")
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement the six test functions in tests/test_app.py"
echo "                 so all pass. Do NOT edit app.py."
echo
echo "Required test names (verifier greps for these exactly):"
echo "  test_health_returns_200"
echo "  test_health_body"
echo "  test_create_task_returns_201"
echo "  test_create_task_has_id"
echo "  test_get_task_returns_200"
echo "  test_get_missing_task_returns_404"
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt"
echo
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-12-flask-production/challenges/05-pytest-suite/verify.sh"
