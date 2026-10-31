# Solution — Validate or Regret It

Two additions to `app.py`: a validation block in `create_user` and a `@app.errorhandler(404)` registration.

```python
# app.py
from flask import Flask, jsonify, request


def create_app():
    app = Flask(__name__)

    @app.route('/users', methods=['POST'])
    def create_user():
        data = request.get_json(silent=True) or {}
        errors = []

        name = data.get('name')
        if not name or not isinstance(name, str) or not name.strip():
            errors.append("'name' is required and must be a non-empty string")

        age = data.get('age')
        if age is None:
            errors.append("'age' is required")
        elif not isinstance(age, int) or isinstance(age, bool):
            errors.append("'age' must be an integer")
        elif not (1 <= age <= 120):
            errors.append("'age' must be between 1 and 120")

        if errors:
            return jsonify({
                'status': 422,
                'error': 'Unprocessable Entity',
                'details': errors,
            }), 422

        return jsonify({'id': 1, 'name': name.strip(), 'age': age}), 201

    @app.errorhandler(404)
    def not_found(exc):
        from flask import request as req
        return jsonify({
            'status': 404,
            'error': 'Not Found',
            'message': f'{req.path} not found',
        }), 404

    return app
```

## Why each piece matters

**Collect all errors before returning.** Returning only the first error forces the caller into a frustrating "fix-and-retry" loop — they discover each problem sequentially instead of once. Use a list so a single POST with three bad fields gets one response listing all three.

**`isinstance(age, bool)` check.** In Python `bool` is a subclass of `int`, so `isinstance(True, int)` is `True`. Without the bool guard, `{"age": true}` passes the integer check and you silently accept a boolean. JSON semantics are strict here; a schema library (pydantic, marshmallow) handles this automatically.

**`@app.errorhandler(404)` on the app factory.** Flask's default 404 is an HTML page — it's a `text/html` response from Werkzeug's exception handler. Registering your own handler on the app replaces it for **every** route the app owns. If you registered the handler on a blueprint instead, routes outside that blueprint would still return HTML.

**`silent=True` on `get_json`.** Without it, a request with a malformed JSON body (bad Content-Type or syntax error) raises a 400 before your code runs. `silent=True` returns `None` instead, letting you return a well-shaped 422 with context.

## Hardening preview

In production, consider a `@app.errorhandler(Exception)` catch-all that logs the traceback server-side and returns a generic 500 envelope — never let a raw Python exception reach the caller:

```python
@app.errorhandler(Exception)
def unhandled(exc):
    app.logger.exception("unhandled error")
    return jsonify({'status': 500, 'error': 'Internal Server Error'}), 500
```
