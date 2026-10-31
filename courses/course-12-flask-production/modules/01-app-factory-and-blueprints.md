# The App Factory & Blueprints

> **Module 01 · Course 12** — Flask is permissive enough to let you build a service in a single file and it will work. The moment you add a second developer, a background worker, a test suite, or a staging environment, that permissiveness becomes technical debt you pay with every deploy. The app factory pattern removes three structural failure modes at once.

---

## The Problem with a Module-Level App Object

The instinctive Flask start looks like this:

```python
# app.py — works locally, breaks at scale
from flask import Flask
from flask_sqlalchemy import SQLAlchemy

app = Flask(__name__)
app.config["SQLALCHEMY_DATABASE_URI"] = "sqlite:///dev.db"
db = SQLAlchemy(app)

from . import routes   # circular import waiting to happen
```

Three failure modes baked in:

1. **Test isolation is impossible.** Every `import app` in your test suite hits the same singleton. You can't configure `TESTING = True`, swap the database URI, or silence side-effecting extensions before they initialize — they already did.
2. **Circular imports.** `routes.py` imports `db` from `app.py`; `app.py` imports routes from `routes.py`. Python sees a half-initialized module and raises `ImportError: cannot import name 'db'` in a way that looks completely unrelated to the real problem.
3. **Config is baked in at import time.** The extensions captured `SQLALCHEMY_DATABASE_URI` the moment Python imported `app.py`. Pulling a new value from the environment or a vault later does nothing — the connection pool already exists.

---

## create_app() — The Factory

The fix is a function that creates, configures, and returns a new `Flask` instance on demand. Nothing is initialized at module import time.

```python
# app/__init__.py
from flask import Flask
from .extensions import db, migrate, login_manager
from .config import config_by_name


def create_app(config_name: str = "development") -> Flask:
    app = Flask(__name__)
    app.config.from_object(config_by_name[config_name])

    db.init_app(app)
    migrate.init_app(app, db)
    login_manager.init_app(app)

    from .api.auth import auth_bp
    from .api.users import users_bp
    app.register_blueprint(auth_bp, url_prefix="/auth")
    app.register_blueprint(users_bp, url_prefix="/users")

    return app
```

```python
# app/extensions.py — extensions without an app, imported freely anywhere
from flask_sqlalchemy import SQLAlchemy
from flask_migrate import Migrate
from flask_login import LoginManager

db = SQLAlchemy()
migrate = Migrate()
login_manager = LoginManager()
```

The structural insight: `extensions.py` imports nothing from your application code. `db` can be imported from `extensions` by models, routes, tests — none of which need to touch the app object. Circular imports are structurally impossible.

Entry points that call the factory:

```python
# wsgi.py — production WSGI entry point
import os
from app import create_app

app = create_app(os.environ.get("FLASK_ENV", "production"))
```

```python
# tests/conftest.py — isolated test app per test session
import pytest
from app import create_app

@pytest.fixture(scope="session")
def app():
    app = create_app("testing")
    yield app

@pytest.fixture(scope="session")
def client(app):
    return app.test_client()
```

---

## Application Context vs Request Context

Two stacked contexts. Getting the model right once prevents a class of runtime errors permanently.

| Context | Pushed when | Proxies it enables | Typical callers |
|---------|-------------|-------------------|-----------------|
| **Application** | `create_app()` entry point, `flask shell`, `flask` CLI, any explicit `app.app_context()` push | `current_app`, `g` | DB migrations, Celery tasks, CLI commands, test fixtures |
| **Request** | An inbound HTTP request arrives (also pushes an app context beneath it) | `request`, `session`, `g` | View functions, `before_request` / `after_request` hooks |

Request context is always pushed *on top of* an application context. Inside a view function you have both. Flask pushes and pops these for you around every request.

The place the model breaks: **background work**. A Celery task, a CLI command, a scheduled job — none of those are HTTP requests. You must push the application context yourself:

```python
# cli.py — flask CLI commands
import click
from flask import current_app
from app.extensions import db
from app.models import User


@click.command("seed-db")
def seed_db():
    # current_app works here because Flask's CLI runner already pushed an app context.
    # In a raw script that isn't `flask <cmd>`, you'd need:
    #   with app.app_context():
    #       ...
    db.session.add(User(email="admin@example.com"))
    db.session.commit()
    click.echo(f"Seeded {current_app.config['SQLALCHEMY_DATABASE_URI']}")
```

```python
# tasks.py — Celery worker context, no request in flight
from app import create_app
from app.extensions import db

flask_app = create_app("production")

def send_welcome_email(user_id: int) -> None:
    with flask_app.app_context():           # explicit push required
        from app.models import User
        user = db.session.get(User, user_id)
        ...                                 # current_app, db.session available here
```

`g` (the global) lives exactly one request: it resets at the end of each request cycle. Cache per-request state there rather than function arguments:

```python
@app.before_request
def load_current_user():
    token = request.headers.get("Authorization", "").removeprefix("Bearer ")
    if token:
        g.current_user = decode_jwt(token)   # available to every view this request
```

---

## Blueprints for Modularity

A blueprint is a deferred collection of routes, error handlers, and hooks that is registered onto an app at startup. Vertical slices instead of a monolithic `routes.py`.

```python
# app/api/auth/__init__.py
from flask import Blueprint

auth_bp = Blueprint("auth", __name__)

from . import routes   # import after the blueprint object exists — no circular issue
```

```python
# app/api/auth/routes.py
from flask import request, jsonify
from . import auth_bp
from app.extensions import db
from app.models import User


@auth_bp.post("/login")
def login():
    data = request.get_json(force=True)
    user = db.session.execute(
        db.select(User).where(User.email == data["email"])
    ).scalar_one_or_none()
    if not user or not user.check_password(data["password"]):
        return jsonify({"error": "invalid credentials"}), 401
    # issue token — see Module 03
    return jsonify({"token": issue_access_token(user)}), 200
```

Blueprint-scoped hooks and error handlers:

```python
@auth_bp.before_request
def require_json():
    if request.method in ("POST", "PUT", "PATCH") and not request.is_json:
        return jsonify({"error": "Content-Type must be application/json"}), 415


# app_errorhandler registers globally; errorhandler only catches errors from this blueprint
@auth_bp.app_errorhandler(404)
def not_found(e):
    return jsonify({"error": "not found"}), 404


@auth_bp.app_errorhandler(500)
def internal_error(e):
    db.session.rollback()   # roll back any open transaction on 500
    return jsonify({"error": "internal server error"}), 500
```

Directory layout that scales to a production service:

```
app/
  __init__.py          # create_app() only
  extensions.py        # db, migrate, login_manager, limiter
  config.py            # Config hierarchy
  models/
    __init__.py
    user.py
    post.py
  api/
    auth/
      __init__.py      # auth_bp
      routes.py
      schemas.py       # marshmallow / pydantic validation
    users/
      __init__.py      # users_bp
      routes.py
  cli.py               # flask CLI commands registered in create_app
wsgi.py                # WSGI entry point
tests/
  conftest.py
  test_auth.py
```

---

## Config Objects & 12-Factor Env Config

The 12-factor model: **configuration lives in the environment, never in code**. The practical Flask implementation is a config class hierarchy.

```python
# app/config.py
import os


class Config:
    # Hard fail on missing required values — a KeyError at startup beats a None in production
    SECRET_KEY: str = os.environ["SECRET_KEY"]
    SQLALCHEMY_TRACK_MODIFICATIONS: bool = False
    JWT_ALGORITHM: str = "HS256"
    JWT_ACCESS_TTL_SECONDS: int = int(os.environ.get("JWT_ACCESS_TTL_SECONDS", "900"))


class DevelopmentConfig(Config):
    DEBUG: bool = True
    SQLALCHEMY_DATABASE_URI: str = os.environ.get(
        "DATABASE_URL", "sqlite:///dev.db"
    )
    SQLALCHEMY_ECHO: bool = True   # logs every SQL statement — invaluable for N+1 hunting


class TestingConfig(Config):
    TESTING: bool = True
    SQLALCHEMY_DATABASE_URI: str = "sqlite:///:memory:"
    # Override directly so tests never need a .env file
    SECRET_KEY: str = "test-secret-not-in-prod"
    WTF_CSRF_ENABLED: bool = False


class ProductionConfig(Config):
    DEBUG: bool = False
    SQLALCHEMY_DATABASE_URI: str = os.environ["DATABASE_URL"]   # hard fail
    SESSION_COOKIE_SECURE: bool = True
    SESSION_COOKIE_HTTPONLY: bool = True
    SESSION_COOKIE_SAMESITE: str = "Lax"
    PROPAGATE_EXCEPTIONS: bool = True   # let Sentry / error reporters see full tracebacks


config_by_name: dict = {
    "development": DevelopmentConfig,
    "testing": TestingConfig,
    "production": ProductionConfig,
}
```

Key decisions worth internalizing:
- `os.environ["KEY"]` (subscript, not `.get()`) for required values. A `KeyError` at boot is visible and actionable. A `None` that reaches your JWT signing code at 2am is neither.
- `TestingConfig.SECRET_KEY` is a class-level attribute override, not an env var read. Tests run without any `.env` file.
- `SQLALCHEMY_ECHO = True` in development surfaces N+1 queries while you write them, not after.

Loading `.env` in development without polluting production:

```python
# wsgi.py
import os

if os.environ.get("FLASK_ENV") == "development":
    from dotenv import load_dotenv
    load_dotenv(override=False)   # override=False: real env vars win over .env

from app import create_app
app = create_app(os.environ.get("FLASK_ENV", "production"))
```

---

## Extension Init Pattern

Every production-grade Flask extension supports deferred initialization. The protocol: `__init__` accepts no `app`; `init_app(app)` binds the extension. This is not a convention — it's what makes multiple apps in one process safe (useful in testing).

What `init_app` does under the hood:
1. Reads extension-specific config keys from `app.config`.
2. Pushes extension state into `app.extensions["name"]` — per-app, not per-process.
3. Registers `app.teardown_appcontext` callbacks to close connections/sessions at request end.

The double-init trap is the most common mistake:

```python
# WRONG — SQLAlchemy binds at construction AND at init_app, registering teardown twice
db = SQLAlchemy(app)
db.init_app(app)

# RIGHT — extensions.py has no app; create_app() calls init_app() exactly once
db = SQLAlchemy()
db.init_app(app)
```

A double-registered `teardown_appcontext` on the session means two `Session.close()` calls per request. Most of the time it's silent; under load it causes intermittent `InvalidRequestError: This session is provisionally present within the registry` errors that are a nightmare to reproduce.

---

## Debugging App Factory & Blueprints

| Symptom | Cause | Fix |
|---------|-------|-----|
| `RuntimeError: Working outside of application context` | Code calls `db.session`, `current_app`, or `g` outside a request with no pushed context | Wrap the code in `with app.app_context():` or use `flask shell` which pushes one automatically |
| `ImportError: cannot import name 'db' from partially initialized module 'app'` | Circular import: a model imports `db` from `app/__init__.py` which tries to import the model | Move all extensions to `extensions.py`; import `db` from there in models, routes, and tests |
| Config key returns `None` at runtime | The env var isn't set, the wrong config class was loaded, or `from_object()` ran before the extension called `init_app` | `flask shell` → `current_app.config` to dump the full config; assert required vars with subscript access |
| Blueprint routes return 404, registration logged no error | `url_prefix` mismatch, or blueprint imported before registration so routes registered on a stale object | Run `flask routes` — every registered URL, blueprint name, and endpoint is listed |
| Extension behaves differently in tests vs dev | Extension initialized twice (passed to constructor AND `init_app`) | Audit `create_app()` — one `init_app()` call per extension per app; never pass `app` to the constructor |
| `AssertionError: The current Flask app is not registered with this 'SQLAlchemy' instance` | `db` was imported from a module that called `SQLAlchemy(app)` directly, not from `extensions.py` | Replace with the factory pattern; there should be exactly one `SQLAlchemy()` in the codebase |

### Exact commands

```bash
# List every registered route: method, endpoint name, URL rule, blueprint
flask routes

# Drop into a Python shell with the app context already pushed
flask shell
>>> from flask import current_app
>>> current_app.config["SQLALCHEMY_DATABASE_URI"]
>>> current_app.extensions.keys()   # see which extensions are bound

# Verbose startup — shows which config class was loaded
FLASK_ENV=development flask --debug run

# Trace import order to find where a circular import originates
# Add temporarily to the top of each suspected module:
import sys; print(f"--- importing {__name__}", file=sys.stderr)

# See all teardown callbacks registered (double-init will show duplicates)
flask shell
>>> app.teardown_appcontext_funcs
```

> **War story.** We had a Celery task that sent a welcome email after user registration. In development it worked — the worker was launched with `flask shell` semantics that push an app context. In production the first task after a cold deploy crashed with `RuntimeError: Working outside of application context`, every time, with no useful traceback beyond the extension call. The root cause: the task module imported a `mail` (Flask-Mail) extension that called `current_app.config["MAIL_SERVER"]` at *module import time*, before any context was pushed. The fix was one line in the Celery `worker_process_init` signal handler: `flask_app.app_context().push()`. We've added a context guard to every background task since. If your code needs `current_app` outside a view function, it needs an explicit context. No exceptions, no shortcuts.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Implement `create_app()` end-to-end: config loading, three extensions `init_app`'d, two blueprints registered.
2. Explain why `db = SQLAlchemy(app)` at module level makes test isolation impossible.
3. Distinguish application context from request context — which proxy globals live in each, and when each is pushed.
4. Write a task function that uses `db.session` outside any HTTP request cycle correctly.
5. Write a `Config` hierarchy where `SECRET_KEY` is required via `os.environ["SECRET_KEY"]` and `TestingConfig` overrides it without reading the environment.
6. Explain `app_errorhandler` vs `errorhandler` on a blueprint and when you'd choose each.
7. Diagnose a circular import by reading the `ImportError` message, not by randomly reordering imports.
8. Run `flask routes` and identify which blueprint and endpoint handles a given URL.

➡ Next: **SQLAlchemy & Migrations** — models, sessions, the N+1 trap, and Alembic.
