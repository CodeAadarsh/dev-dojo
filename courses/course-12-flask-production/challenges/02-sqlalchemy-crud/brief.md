# Notes CRUD with SQLAlchemy

The ticket lands in your queue: *"Replace the in-memory list with a real database so notes survive a restart."* The existing code uses a module-level `items = []` and breaks the moment there are two workers. Your job: define a `Note` model and wire five endpoints to SQLite using Flask-SQLAlchemy — the same ORM pattern you'll reach for every time you need a relational store behind a Flask API.

## Working directory

`setup.sh` plants a skeleton in:

```
~/.kube-dojo-work/02-sqlalchemy-crud/
  app.py             ← implement Note model + CRUD here
  tests/
    test_harness.py  ← DO NOT EDIT (run by verify.sh)
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/02-sqlalchemy-crud
python3 -m venv .venv && . .venv/bin/activate
pip install flask pytest flask-sqlalchemy
```

## Mission

Edit `app.py`. You must:

1. Define a `Note` model with: `id` (Integer primary key), `title` (String, non-null), `body` (Text, nullable). Add a `to_dict()` helper that returns a plain dict.
2. Call `db.create_all()` inside an `app.app_context()` block within `create_app()` so the table exists on startup.
3. Implement the five endpoint bodies:

| Endpoint | Method | Status |
|----------|--------|--------|
| `POST /notes` | create | **201** Created — return new note dict |
| `GET /notes` | list | **200** OK — return array of note dicts |
| `GET /notes/<id>` | fetch one | **200** OK or **404** Not Found |
| `PUT /notes/<id>` | replace | **200** OK or **404** Not Found |
| `DELETE /notes/<id>` | remove | **204** No Content or **404** Not Found |

`create_app(test_config=None)` already handles accepting a config dict and calling `db.init_app(app)` — you only need to fill in the model and the route bodies.

## Why it matters

The SQLAlchemy session (`db.session`) is request-scoped by Flask-SQLAlchemy. That means you get one unit-of-work per HTTP request: add objects, call `commit()`, and the session is cleaned up automatically when the response is sent. Forgetting `commit()` is the number-one cause of "my data disappeared" bugs. `db.session.get(Note, id)` is the correct way to fetch by primary key in SQLAlchemy 2.x — `Model.query.get(id)` is deprecated and will be removed.

## Verify

```bash
bash courses/course-12-flask-production/challenges/02-sqlalchemy-crud/verify.sh
```

All eight harness tests green → flag printed.
