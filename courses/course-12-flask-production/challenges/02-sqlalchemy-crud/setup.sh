#!/usr/bin/env bash
# Plants the "Notes CRUD with SQLAlchemy" challenge skeleton.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/02-sqlalchemy-crud"
mkdir -p "$WORK/tests"

# ── app.py skeleton ──────────────────────────────────────────────────────────
cat > "$WORK/app.py" << 'PYEOF'
from flask import Flask, jsonify, request
from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()


# TODO: define the Note model here.
# Required columns: id (Integer, primary key), title (String(200), nullable=False),
# body (Text, nullable=True).
# Add a to_dict() method that returns a plain Python dict.


def create_app(test_config=None):
    app = Flask(__name__)
    app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///notes.db'
    if test_config:
        app.config.update(test_config)
    db.init_app(app)

    # TODO: call db.create_all() inside an app.app_context() block here
    # so the table is created on startup.

    @app.route('/notes', methods=['POST'])
    def create_note():
        # Parse JSON body; create a Note; add + commit; return note.to_dict() with 201.
        return jsonify({'error': 'not implemented'}), 501

    @app.route('/notes')
    def list_notes():
        # Return a list of all note dicts with 200.
        return jsonify({'error': 'not implemented'}), 501

    @app.route('/notes/<int:note_id>')
    def get_note(note_id):
        # Fetch by id; 404 if missing; return note.to_dict() with 200.
        return jsonify({'error': 'not implemented'}), 501

    @app.route('/notes/<int:note_id>', methods=['PUT'])
    def update_note(note_id):
        # Fetch by id; 404 if missing; update title/body from JSON; commit; return dict.
        return jsonify({'error': 'not implemented'}), 501

    @app.route('/notes/<int:note_id>', methods=['DELETE'])
    def delete_note(note_id):
        # Fetch by id; 404 if missing; delete; commit; return empty string with 204.
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

import pytest
from app import create_app, db


@pytest.fixture
def client(tmp_path):
    db_path = str(tmp_path / 'test.db')
    app = create_app({'TESTING': True, 'SQLALCHEMY_DATABASE_URI': f'sqlite:///{db_path}'})
    with app.test_client() as c:
        yield c


def test_create_note_returns_201(client):
    rv = client.post('/notes', json={'title': 'Buy milk', 'body': 'whole milk'})
    assert rv.status_code == 201, f"POST /notes must return 201, got {rv.status_code}"
    data = rv.get_json()
    assert data is not None, "POST /notes must return a JSON body"
    assert 'id' in data, "response must include an 'id' field"
    assert data['title'] == 'Buy milk', f"title mismatch: {data}"


def test_list_notes_returns_200(client):
    rv = client.get('/notes')
    assert rv.status_code == 200, f"GET /notes must return 200, got {rv.status_code}"
    assert isinstance(rv.get_json(), list), "GET /notes must return a JSON array"


def test_get_existing_note(client):
    create = client.post('/notes', json={'title': 'Test note', 'body': 'hello'})
    assert create.status_code == 201
    note_id = create.get_json()['id']
    rv = client.get(f'/notes/{note_id}')
    assert rv.status_code == 200, f"GET /notes/{note_id} must return 200, got {rv.status_code}"
    assert rv.get_json()['title'] == 'Test note'


def test_get_missing_note_returns_404(client):
    rv = client.get('/notes/999999')
    assert rv.status_code == 404, f"GET /notes/999999 must return 404, got {rv.status_code}"


def test_update_note(client):
    create = client.post('/notes', json={'title': 'Old title', 'body': ''})
    assert create.status_code == 201
    note_id = create.get_json()['id']
    rv = client.put(f'/notes/{note_id}', json={'title': 'New title', 'body': 'updated'})
    assert rv.status_code == 200, f"PUT /notes/{note_id} must return 200, got {rv.status_code}"
    assert rv.get_json()['title'] == 'New title', f"title not updated: {rv.get_json()}"


def test_update_missing_note_returns_404(client):
    rv = client.put('/notes/999999', json={'title': 'X', 'body': ''})
    assert rv.status_code == 404, f"PUT /notes/999999 must return 404, got {rv.status_code}"


def test_delete_note_returns_204(client):
    create = client.post('/notes', json={'title': 'Trash', 'body': ''})
    assert create.status_code == 201
    note_id = create.get_json()['id']
    rv = client.delete(f'/notes/{note_id}')
    assert rv.status_code == 204, f"DELETE /notes/{note_id} must return 204, got {rv.status_code}"


def test_delete_missing_note_returns_404(client):
    rv = client.delete('/notes/999999')
    assert rv.status_code == 404, f"DELETE /notes/999999 must return 404, got {rv.status_code}"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : define the Note model and implement the five CRUD endpoint"
echo "                 bodies in app.py so the eight harness tests pass."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install flask pytest flask-sqlalchemy"
echo
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-12-flask-production/challenges/02-sqlalchemy-crud/verify.sh"
