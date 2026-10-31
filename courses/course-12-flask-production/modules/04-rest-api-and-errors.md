# REST APIs, Validation & Error Handling

> **Module 04 · Course 12** — The most common Flask API anti-patterns aren't bad endpoints — they're leaking Python tracebacks to clients, returning `200` with `{"error": "something went wrong"}`, and silently accepting inputs the app was never designed to handle. This module closes those gaps.

You already know how to write a Flask route. This is about writing routes that behave correctly under adversarial inputs, fail predictably, and compose cleanly as a codebase grows.

---

## Blueprint-based API structure

A single `app.py` file works until the moment it doesn't. The threshold is lower than you think — once you have auth, health checks, and two resources, the file becomes a liability.

The correct structure wires blueprints through the app factory:

```python
# app/__init__.py
from flask import Flask
from .api.users import users_bp
from .api.health import health_bp
from .errors import register_error_handlers

def create_app(config_name="default"):
    app = Flask(__name__)
    app.config.from_object(config[config_name])

    app.register_blueprint(health_bp)
    app.register_blueprint(users_bp, url_prefix="/api/v1")

    register_error_handlers(app)
    return app
```

```python
# app/api/users.py
from flask import Blueprint, request, jsonify
from ..schemas import CreateUserSchema
from ..models import User, db

users_bp = Blueprint("users", __name__)

@users_bp.route("/users", methods=["POST"])
def create_user():
    data = CreateUserSchema().load(request.get_json(force=True, silent=True) or {})
    user = User(**data)
    db.session.add(user)
    db.session.commit()
    return jsonify(user.to_dict()), 201
```

Blueprint `url_prefix` at registration time (not at `Blueprint()` creation) keeps the blueprint reusable — you can mount it at `/v1` and `/v2` from the same class. The prefix belongs to the caller, not the module.

**The circular import trap:** `create_app` imports blueprints, blueprints import models, models import `db` from `app.extensions`, `app.extensions` never imports `app`. Draw that dependency graph before you start. If anything in `api/` imports from `app/__init__.py`, you have a cycle waiting to fail on first import.

---

## Request validation: pydantic v2 vs marshmallow

Both are viable; pick one per project and stay consistent. The key differences:

| Concern | Pydantic v2 | marshmallow |
|---------|-------------|-------------|
| Validation approach | Type-annotated models | Schema with `fields.*` |
| Speed | ~10x faster (Rust core in v2) | Interpreted Python |
| Load/dump | `model_validate` / `model_dump` | `schema.load()` / `schema.dump()` |
| Error format | `ValidationError.errors()` — list of `{loc, msg, type}` | `ValidationError.messages` — nested dict |
| Flask integration | Manual or `flask-pydantic` | `flask-marshmallow` or manual |

### Pydantic v2

```python
from pydantic import BaseModel, EmailStr, field_validator, ValidationError
from flask import request, jsonify
from functools import wraps

class CreateUserInput(BaseModel):
    email: EmailStr
    name: str
    age: int | None = None

    @field_validator("name")
    @classmethod
    def name_not_blank(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("name cannot be blank")
        return v.strip()


def validated(schema_cls):
    """Decorator: parse+validate the JSON body, inject as first arg."""
    def decorator(f):
        @wraps(f)
        def wrapper(*args, **kwargs):
            try:
                data = schema_cls.model_validate(
                    request.get_json(force=True, silent=True) or {}
                )
            except ValidationError as exc:
                return jsonify({
                    "error": {
                        "code": "VALIDATION_ERROR",
                        "message": "Request body is invalid.",
                        "details": exc.errors(include_url=False),
                    }
                }), 422
            return f(data, *args, **kwargs)
        return wrapper
    return decorator


@users_bp.route("/users", methods=["POST"])
@validated(CreateUserInput)
def create_user(body: CreateUserInput):
    ...
```

`include_url=False` removes the pydantic docs URL from error messages — clients don't need it.

### Marshmallow

```python
from marshmallow import Schema, fields, validate, validates, ValidationError, post_load

class CreateUserSchema(Schema):
    email = fields.Email(required=True)
    name = fields.Str(required=True, validate=validate.Length(min=1, max=120))
    age = fields.Int(load_default=None, validate=validate.Range(min=0, max=150))

    @validates("name")
    def validate_name(self, value):
        if not value.strip():
            raise ValidationError("name cannot be blank")

    @post_load
    def strip_name(self, data, **kwargs):
        data["name"] = data["name"].strip()
        return data
```

`@post_load` transforms data after validation — use it for normalization (stripping whitespace, lowercasing emails), not for business logic.

---

## Consistent JSON error envelopes

The goal is a single shape for every error, regardless of where in the stack it originates:

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Request body is invalid.",
    "details": [
      {"loc": ["email"], "msg": "value is not a valid email address"}
    ]
  }
}
```

`code` is a machine-readable constant (screaming snake case). Clients branch on `code`, not HTTP status codes alone. This matters the moment a frontend or mobile app needs to show a specific message for a specific error.

Register all handlers in one place:

```python
# app/errors.py
from flask import jsonify
from werkzeug.exceptions import HTTPException

def register_error_handlers(app):

    @app.errorhandler(400)
    def bad_request(e):
        return jsonify({"error": {"code": "BAD_REQUEST", "message": str(e)}}), 400

    @app.errorhandler(404)
    def not_found(e):
        return jsonify({"error": {"code": "NOT_FOUND", "message": "Resource not found."}}), 404

    @app.errorhandler(405)
    def method_not_allowed(e):
        return jsonify({"error": {"code": "METHOD_NOT_ALLOWED", "message": str(e)}}), 405

    @app.errorhandler(422)
    def unprocessable(e):
        return jsonify({"error": {"code": "UNPROCESSABLE_ENTITY", "message": str(e)}}), 422

    @app.errorhandler(500)
    def internal_error(e):
        app.logger.exception("Unhandled exception")
        return jsonify({"error": {"code": "INTERNAL_ERROR", "message": "An unexpected error occurred."}}), 500

    @app.errorhandler(HTTPException)
    def handle_http_exception(e):
        return jsonify({"error": {"code": e.name.upper().replace(" ", "_"), "message": e.description}}), e.code
```

The `HTTPException` catch-all handles every Werkzeug HTTP exception (412, 429, 503, etc.) you didn't register explicitly.

**400 vs 422:** Use 400 for structurally malformed requests (unparseable JSON, wrong `Content-Type`). Use 422 for semantically invalid requests (valid JSON, but wrong field values). Flask raises 400 for `get_json(force=False)` when the body isn't JSON — be intentional about which you return.

---

## Content negotiation

A pure API should respond to `Accept: text/html` (browser curl, misconfigured client) correctly:

```python
from flask import request, jsonify, Response

def negotiate(data, status=200):
    best = request.accept_mimetypes.best_match(["application/json", "text/html"])
    if best == "text/html":
        return Response("This API only serves JSON.", status=406, mimetype="text/plain")
    return jsonify(data), status
```

In practice most teams skip negotiation entirely and force JSON. The important part is ensuring your error handlers also return `application/json`, not the default Werkzeug HTML error pages. That `Content-Type: text/html` response to a JSON client is where client SDKs fail to parse the error and surface a confusing crash.

---

## Pagination

Two patterns — cursor-based is right more often:

### Offset pagination (simple, breaks at scale)

```python
DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 100

@users_bp.route("/users", methods=["GET"])
def list_users():
    page = request.args.get("page", 1, type=int)
    per_page = min(request.args.get("per_page", DEFAULT_PAGE_SIZE, type=int), MAX_PAGE_SIZE)

    paginator = User.query.order_by(User.id).paginate(
        page=page, per_page=per_page, error_out=False
    )
    return jsonify({
        "data": [u.to_dict() for u in paginator.items],
        "pagination": {
            "page": page,
            "per_page": per_page,
            "total": paginator.total,
            "pages": paginator.pages,
        }
    })
```

Offset pagination breaks when rows are inserted between page fetches — page 2 silently skips a row inserted at the boundary. For low-churn internal tools that's acceptable.

### Cursor pagination (correct at scale)

```python
import base64

@users_bp.route("/users", methods=["GET"])
def list_users():
    limit = min(request.args.get("limit", 20, type=int), 100)
    after = request.args.get("after")

    query = User.query.order_by(User.id)
    if after:
        try:
            last_id = int(base64.b64decode(after).decode())
            query = query.filter(User.id > last_id)
        except Exception:
            return jsonify({"error": {"code": "INVALID_CURSOR", "message": "Cursor is invalid."}}), 400

    users = query.limit(limit + 1).all()
    has_more = len(users) > limit
    users = users[:limit]

    next_cursor = None
    if has_more and users:
        next_cursor = base64.b64encode(str(users[-1].id).encode()).decode()

    return jsonify({
        "data": [u.to_dict() for u in users],
        "pagination": {"limit": limit, "next": next_cursor, "has_more": has_more}
    })
```

The cursor is base64-encoded to signal "treat this as opaque." The actual value can evolve without breaking clients that store and replay it. Fetch `limit + 1` rows to detect `has_more` without a separate `COUNT(*)` query.

---

## Debugging REST APIs & Error Handling

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Client receives an HTML page with `RuntimeError` traceback | `DEBUG=True` in production, or no `500` handler registered | Set `DEBUG=False`; register `@app.errorhandler(500)` that logs internally and returns JSON |
| Different endpoints return `{"error": "..."}`, `{"message": "..."}`, `{"detail": "..."}` for the same kind of failure | No central error envelope; each route or handler invented its own format | Move all error responses through `register_error_handlers`; write a contract test that asserts `body["error"]["code"]` is present on every 4xx |
| Validation passes for a field that was intentionally absent | Schema field has `required=False` by default, or `load_default` silently fills it; or `get_json()` returned `None` | Audit schema defaults; use `get_json(force=True, silent=True) or {}` to never pass `None` to `.load()` |
| `abort(404)` returns HTML, not JSON | `errorhandler(404)` not registered, or a blueprint registered its own 404 handler that wins | Register all handlers in `register_error_handlers` called inside `create_app` after all blueprints |
| Pydantic 422 for a field that should accept `null` | `int` instead of `int \| None`; pydantic treats absent+null differently | `age: int \| None = None` in pydantic; `load_default=None` in marshmallow |
| Page 2 of a list skips records | Rows inserted between requests shift the offset window | Switch to cursor-based; or acknowledge the limitation for low-churn data |

### Exact diagnosis commands

```bash
# Confirm what Content-Type your error responses carry
curl -s -i -X POST http://localhost:5000/api/v1/users \
  -H 'Content-Type: application/json' \
  -d '{"invalid": true}' | head -20

# Trigger a 404 and inspect the exact shape
curl -s http://localhost:5000/api/v1/nonexistent | python3 -m json.tool

# Check whether DEBUG=True is leaking a traceback
curl -s -X POST http://localhost:5000/api/v1/users -d 'not json' | grep -i traceback

# Run pydantic validation standalone to inspect the error format
python3 -c "
from app.schemas import CreateUserInput
from pydantic import ValidationError
try:
    CreateUserInput.model_validate({'name': ''})
except ValidationError as e:
    import json; print(json.dumps(e.errors(include_url=False), indent=2))
"

# Confirm all 4xx responses have the envelope shape
for code in 400 404 405 422; do
  echo -n "HTTP $code → "; curl -s "http://localhost:5000/_test/$code" | python3 -c "import sys,json; d=json.load(sys.stdin); print('OK' if 'error' in d and 'code' in d['error'] else 'MISSING ENVELOPE')"
done
```

> **War story.** At a previous project, a mobile client started crashing for 1% of users after a deploy. The backend was returning `{"error": "User not found"}` from one handler and `{"message": "user not found"}` from another — same semantics, different key. The mobile client branched on the `error` key and silently swallowed the `message` version, leaving users in a broken state with no visible error. Two hours of debugging, one-line fix. A contract test asserting the shape of every 4xx response would have caught it in CI. We wrote the test the same day and it's been there ever since.

---

## Checkpoint

You're ready for the challenge when you can:

1. Register two blueprints in an app factory — one at `/health`, one at `/api/v1` — without circular imports.
2. Write a pydantic v2 model and a marshmallow schema for the same input; state one concrete trade-off between them.
3. Return `{"error": {"code": "...", "message": "...", "details": [...]}}` from a 422 handler and confirm the shape with `curl -s | python3 -m json.tool`.
4. Register a `500` handler that logs the exception internally and returns JSON without leaking the Python traceback.
5. Explain when 400 is correct versus when 422 is correct — give a concrete example of each.
6. Implement cursor-based pagination that doesn't skip rows on insertion.
7. Diagnose a route that returns HTML for a 404 by identifying the missing or mis-ordered handler registration.

➡ Next up: the **Tame the 500** challenge — you'll add validation and error handlers to a broken API and prove it with a pytest suite.
