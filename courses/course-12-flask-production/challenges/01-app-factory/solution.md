# Solution — The App Factory

Two files to edit: `app/__init__.py` and `app/views.py`.

## app/views.py

```python
from flask import Blueprint, jsonify

main = Blueprint('main', __name__)


@main.route('/health')
def health():
    return jsonify({'status': 'ok'})


@main.route('/version')
def version():
    return jsonify({'version': '1.0.0'})
```

## app/__init__.py

```python
from flask import Flask
from .views import main


def create_app():
    app = Flask(__name__)
    app.register_blueprint(main)
    return app
```

## Why each piece is required

**`create_app()` returns a new instance on each call.** The verifier checks this explicitly (`a1 is not a2`). The factory must not assign `app` at module scope — if it does, every call returns the same object, defeating isolation. Any test that calls `create_app()` should get a clean, independently-configurable instance.

**`app.register_blueprint(main)` inside the factory.** Blueprint registration wires the blueprint's routes into the app's URL map. You can have multiple blueprints (e.g. `api`, `admin`, `health`) each defined in their own module, registered in order inside the factory. This keeps route definitions out of `__init__.py` and makes individual blueprints unit-testable by mounting them on a fresh app.

**`Blueprint('main', __name__)`** — the first argument is the blueprint's name. Flask uses it as a prefix for endpoint names: the endpoint for `/health` becomes `main.health`, not just `health`. The verifier checks for a `.` in the endpoint string to confirm the route lives on a blueprint rather than directly on the app. This is also how `url_for('main.health')` works in templates.

**The `from .views import main` relative import.** This works because `app/` is a package (it has `__init__.py`). Using a relative import keeps the factory decoupled from the filesystem path — if you rename the package, the import still works.

## Apply and verify

```bash
cd ~/.kube-dojo-work/01-app-factory
# replace app/__init__.py and app/views.py with the solution above, then:
.venv/bin/pytest tests/ -v
bash courses/course-12-flask-production/challenges/01-app-factory/verify.sh
```
