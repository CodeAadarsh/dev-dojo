#!/usr/bin/env bash
# Plants the "Dependency Injection" starter project into the work directory.
# Idempotent — re-running overwrites source files but does not touch .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/03-dependency-injection"
mkdir -p "$WORK/tests"

# ── main.py skeleton ─────────────────────────────────────────────────────────
cat > "$WORK/main.py" << 'PYEOF'
# main.py — task API skeleton
#
# Three refactors needed:
#
# REFACTOR 1 — get_db() yield dependency
#   Define a module-level get_db() function that yields _store.
#   Update all three route functions to accept db: dict = Depends(get_db)
#   and replace every reference to _store with db.
#
# REFACTOR 2 — Settings via pydantic-settings
#   Add: from pydantic_settings import BaseSettings
#   Define Settings(BaseSettings) with app_name: str = "Task API"
#   Instantiate: settings = Settings()
#
# REFACTOR 3 — APIRouter with prefix="/tasks"
#   Move the three routes to an APIRouter(prefix="/tasks") and
#   include it in app with app.include_router(router).
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI()

# Anti-pattern: module-level store shared across all requests and tests.
_store: dict = {}
_next_id: int = 1


class TaskCreate(BaseModel):
    title: str
    done: bool = False


class Task(TaskCreate):
    id: int


@app.post("/tasks", status_code=201)
def create_task(task: TaskCreate) -> Task:
    global _next_id
    new_task = Task(id=_next_id, **task.model_dump())
    _store[_next_id] = new_task     # BUG: uses global _store, not injected dependency
    _next_id += 1
    return new_task


@app.get("/tasks")
def list_tasks() -> list[Task]:
    return list(_store.values())    # BUG: uses global _store


@app.get("/tasks/{task_id}")
def get_task(task_id: int) -> Task:
    if task_id not in _store:       # BUG: uses global _store
        raise HTTPException(status_code=404, detail="task not found")
    return _store[task_id]
PYEOF

# ── tests/test_tasks.py (visible harness) ─────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_tasks.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest
from fastapi.testclient import TestClient

try:
    from main import app, get_db
    HAS_GET_DB = True
except ImportError:
    from main import app
    HAS_GET_DB = False


def make_client(store=None):
    """Create a TestClient with an isolated store via DI override."""
    if HAS_GET_DB and store is not None:
        captured = store

        def _override():
            yield captured

        app.dependency_overrides[get_db] = _override
    return TestClient(app)


def test_get_db_is_injectable():
    assert HAS_GET_DB, (
        "get_db must be importable from main. "
        "Define a module-level `def get_db(): yield _store` and "
        "import it at the top of this file."
    )


def test_create_task_201():
    client = make_client({})
    r = client.post("/tasks", json={"title": "Write tests", "done": False})
    assert r.status_code == 201, f"POST /tasks must return 201, got {r.status_code}"
    assert "id" in r.json(), "response must include 'id'"


def test_list_tasks():
    store = {}
    client = make_client(store)
    client.post("/tasks", json={"title": "T1", "done": False})
    r = client.get("/tasks")
    assert r.status_code == 200
    assert isinstance(r.json(), list), "GET /tasks must return a JSON array"


def test_get_missing_404():
    client = make_client({})
    r = client.get("/tasks/99999")
    assert r.status_code == 404


def test_dependency_isolation():
    """Routes must use Depends(get_db), not the global _store."""
    store_a = {}
    client_a = make_client(store_a)
    client_a.post("/tasks", json={"title": "Leaked?", "done": False})

    store_b = {}
    client_b = make_client(store_b)
    r = client_b.get("/tasks")
    assert r.status_code == 200
    tasks = r.json()
    assert len(tasks) == 0, (
        f"Expected 0 tasks in isolated store_b, found {len(tasks)}. "
        "Routes are still reading from the global _store instead of the injected db. "
        "Replace every `_store[...]` with `db[...]` and add `db: dict = Depends(get_db)` "
        "to each route signature."
    )


def test_settings_has_app_name():
    try:
        from main import settings
    except ImportError:
        pytest.fail(
            "settings must be importable from main. "
            "Add: from pydantic_settings import BaseSettings; "
            "class Settings(BaseSettings): app_name: str = 'Task API'; "
            "settings = Settings()"
        )
    assert hasattr(settings, "app_name"), (
        "settings object must have an 'app_name' attribute. "
        "Add `app_name: str = 'Task API'` to your Settings class."
    )
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : apply the three refactors described in main.py"
echo "                 so all 6 tests in tests/test_tasks.py pass."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install fastapi 'uvicorn[standard]' httpx pytest pydantic sqlalchemy pyjwt pydantic-settings"
echo
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-15-fastapi-production/challenges/03-dependency-injection/verify.sh"
