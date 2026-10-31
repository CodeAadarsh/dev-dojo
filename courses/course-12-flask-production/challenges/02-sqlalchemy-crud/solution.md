# Solution — Notes CRUD with SQLAlchemy

One file to edit: `app.py`. The complete implementation:

```python
from flask import Flask, jsonify, request
from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()


class Note(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    title = db.Column(db.String(200), nullable=False)
    body = db.Column(db.Text, nullable=True)

    def to_dict(self):
        return {'id': self.id, 'title': self.title, 'body': self.body}


def create_app(test_config=None):
    app = Flask(__name__)
    app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///notes.db'
    if test_config:
        app.config.update(test_config)
    db.init_app(app)
    with app.app_context():
        db.create_all()

    @app.route('/notes', methods=['POST'])
    def create_note():
        data = request.get_json(silent=True) or {}
        note = Note(title=data.get('title', ''), body=data.get('body'))
        db.session.add(note)
        db.session.commit()
        return jsonify(note.to_dict()), 201

    @app.route('/notes')
    def list_notes():
        return jsonify([n.to_dict() for n in db.session.execute(db.select(Note)).scalars()])

    @app.route('/notes/<int:note_id>')
    def get_note(note_id):
        note = db.session.get(Note, note_id)
        if note is None:
            return jsonify({'error': 'Not Found'}), 404
        return jsonify(note.to_dict())

    @app.route('/notes/<int:note_id>', methods=['PUT'])
    def update_note(note_id):
        note = db.session.get(Note, note_id)
        if note is None:
            return jsonify({'error': 'Not Found'}), 404
        data = request.get_json(silent=True) or {}
        note.title = data.get('title', note.title)
        note.body = data.get('body', note.body)
        db.session.commit()
        return jsonify(note.to_dict())

    @app.route('/notes/<int:note_id>', methods=['DELETE'])
    def delete_note(note_id):
        note = db.session.get(Note, note_id)
        if note is None:
            return jsonify({'error': 'Not Found'}), 404
        db.session.delete(note)
        db.session.commit()
        return '', 204

    return app
```

## Why each piece is required

**`db = SQLAlchemy()` at module scope, `db.init_app(app)` inside the factory.** This is the extension split pattern: the `db` object is created once per module (so models can reference it at class definition time), but it is not bound to any app yet. `init_app()` binds it to the specific app instance inside the factory. This is what allows `from app import db` to work in tests while still supporting the factory pattern.

**`with app.app_context(): db.create_all()`** creates the SQLite schema immediately when `create_app()` is called. The app context is required because `db.create_all()` needs to know which app's config (and thus which database URL) to use. Without the explicit push, Flask raises `RuntimeError: No application found`.

**`db.session.get(Note, note_id)` vs `Note.query.get(note_id)`.** The `query` interface is the SQLAlchemy 1.x legacy API, deprecated in 2.x and removed in Flask-SQLAlchemy 3.x. `db.session.get()` is the correct pattern going forward — it maps directly to the SQLAlchemy 2.x `Session.get()`.

**`return '', 204` on DELETE.** HTTP 204 No Content must not have a response body. Returning `jsonify({})` sends an empty JSON object, which is technically a body — some strict clients will reject it. An empty string `''` with status `204` is correct.

**`silent=True` on `get_json()`.** Without it, a request with no `Content-Type: application/json` header raises a 400 before your route body runs, and the error won't be your clean 404/200. `silent=True` returns `None` instead, letting you default to `{}` safely.

## Attacker's view

The `Note.body` column accepts arbitrary text — if you later render it in HTML without escaping, you have a stored XSS. `jsonify()` escapes HTML entities by default in Flask (`<` → `<`), so API responses are safe. The risk is if you ever render the body server-side in a Jinja template without `|e`.

## Apply and verify

```bash
cd ~/.kube-dojo-work/02-sqlalchemy-crud
# replace app.py with the solution above, then:
.venv/bin/pytest tests/ -v
bash courses/course-12-flask-production/challenges/02-sqlalchemy-crud/verify.sh
```
