# Dependency Injection

A code review comment on the task service: *"All routes read/write a module-level `_store` dict. Tests can't isolate — they share state. Wire up a real `Depends(get_db)` so we can override the store per test."*

Your job: refactor `main.py` so the six-test harness passes, including the DI isolation test that catches shared global state.

## Context

`setup.sh` plants the starter in your work directory:

```
~/.kube-dojo-work/03-dependency-injection/
├── main.py          # FastAPI task API — works, but all routes use global _store
└── tests/
    └── test_tasks.py   # six-test harness; the isolation test is the hard one
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/03-dependency-injection
python3 -m venv .venv && . .venv/bin/activate
pip install fastapi "uvicorn[standard]" httpx pytest pydantic sqlalchemy pyjwt pydantic-settings
```

## Mission

Three refactors to `main.py`:

### 1 — `get_db()` yield dependency

Define a module-level `get_db` function that yields `_store`. Routes must receive the store via `db: dict = Depends(get_db)` and use `db` instead of the global `_store`.

```python
_store: dict = {}

def get_db():
    yield _store
```

The test overrides this with a per-test fresh dict via `app.dependency_overrides[get_db] = ...`.

### 2 — `Settings` via `pydantic-settings`

Add a `Settings(BaseSettings)` class with at least `app_name: str = "Task API"`. Instantiate it as `settings = Settings()` at module level. The test imports `settings` from `main` and checks `hasattr(settings, 'app_name')`.

### 3 — `APIRouter` with prefix `/tasks`

Move the three route functions onto an `APIRouter(prefix="/tasks")` and include it in `app`.

## The harness asserts

| Test | Requirement |
|------|-------------|
| `test_get_db_is_injectable` | `get_db` must be importable from `main` |
| `test_create_task_201` | POST /tasks → 201 with `id` |
| `test_list_tasks` | GET /tasks → 200, JSON array |
| `test_get_missing_404` | GET /tasks/99999 → 404 |
| `test_dependency_isolation` | Two clients with separate DI overrides must not share state |
| `test_settings_has_app_name` | `settings` importable from `main`, has `app_name` attribute |

## The isolation test in detail

```python
store_a = {}
app.dependency_overrides[get_db] = lambda: iter([store_a])
client_a = TestClient(app)
client_a.post("/tasks", json={"title": "Leaked?", "done": False})

store_b = {}
app.dependency_overrides[get_db] = lambda: iter([store_b])
client_b = TestClient(app)
r = client_b.get("/tasks")
assert len(r.json()) == 0   # FAILS if routes use global _store
```

Routes that use `Depends(get_db)` and read from the injected `db` see an empty `store_b`. Routes that still reference `_store` directly see the task written by `client_a`. The test catches the leak.

## Verify

```bash
bash courses/course-15-fastapi-production/challenges/03-dependency-injection/verify.sh
```

All six tests green → flag printed.
