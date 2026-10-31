# The App Factory

A new teammate pushed a Flask service with `app = Flask(__name__)` at module scope. Everything looked fine until you tried to run two test configurations in the same pytest session — one pointing at the production database URL and one using an in-memory SQLite. Both tests ran against the same `app` object, the same config, and the same state. Half the tests failed on CI for no obvious reason and the bug took an hour to track down.

The fix is the **application factory pattern**: a `create_app()` function that constructs and returns a fresh `Flask` instance on every call. Flask itself recommends it; Flask-SQLAlchemy, Flask-Login, and Flask-Migrate all require it.

## Working directory

`setup.sh` plants a skeleton in:

```
~/.kube-dojo-work/01-app-factory/
  app/
    __init__.py      ← implement create_app() here
    views.py         ← define the Blueprint and its routes here
  tests/
    test_harness.py  ← DO NOT EDIT (run by verify.sh)
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/01-app-factory
python3 -m venv .venv && . .venv/bin/activate
pip install flask pytest
```

## Mission

Implement `create_app()` in `app/__init__.py` and the two route handlers in `app/views.py`.

**`create_app()` must:**

1. Construct and return a fresh `Flask` instance on each call — no module-level singleton.
2. Register the `main` Blueprint defined in `app/views.py` via `app.register_blueprint(main)`.

**Through that Blueprint, expose:**

| Endpoint | Method | Required response |
|----------|--------|-------------------|
| `/health` | GET | `200 OK` with body `{"status": "ok"}` |
| `/version` | GET | `200 OK` with body containing a `"version"` key |

The verifier checks that `/health` is served by a Blueprint endpoint (its URL rule's `endpoint` attribute contains `.`), not a bare function registered directly on `app`. This distinction is what makes the pattern composable — blueprints are mountable, reusable, and independently testable.

## Why it matters

Without the factory, the module-level `app` is constructed once at import time. Any config applied before that import is locked in. Every test that touches `from app import app` shares the same object, the same database connection, and the same in-memory state — there is no isolation. With `create_app()`, a test fixture calls it fresh, configures it for testing, and tears it down without touching any other test's instance. This is the pattern that makes Flask applications actually testable.

## Verify

```bash
bash courses/course-12-flask-production/challenges/01-app-factory/verify.sh
```

All six harness tests green → flag printed.
