# Solution — Dependency Injection

Three targeted refactors to `main.py`. No logic changes — only structure.

```python
# main.py — task API, properly wired
from fastapi import APIRouter, Depends, FastAPI, HTTPException
from pydantic import BaseModel
from pydantic_settings import BaseSettings


# REFACTOR 2: settings
class Settings(BaseSettings):
    app_name: str = "Task API"


settings = Settings()

app = FastAPI(title=settings.app_name)

# REFACTOR 1: module-level store + get_db yield dependency
_store: dict = {}
_next_id: int = 1


def get_db():
    yield _store


# REFACTOR 3: APIRouter with prefix
router = APIRouter(prefix="/tasks")


class TaskCreate(BaseModel):
    title: str
    done: bool = False


class Task(TaskCreate):
    id: int


@router.post("/", status_code=201)
def create_task(task: TaskCreate, db: dict = Depends(get_db)) -> Task:
    global _next_id
    new_task = Task(id=_next_id, **task.model_dump())
    db[_next_id] = new_task
    _next_id += 1
    return new_task


@router.get("/")
def list_tasks(db: dict = Depends(get_db)) -> list[Task]:
    return list(db.values())


@router.get("/{task_id}")
def get_task(task_id: int, db: dict = Depends(get_db)) -> Task:
    if task_id not in db:
        raise HTTPException(status_code=404, detail="task not found")
    return db[task_id]


app.include_router(router)
```

## Why each refactor matters

**REFACTOR 1: `get_db()` yield dependency.**
Moving the store into a yield dependency decouples routes from the global `_store`. The critical consequence: tests can inject a fresh `{}` per test via `app.dependency_overrides[get_db] = lambda: iter([{}])`, and routes that use `db` (the injected value) instead of `_store` (the global) will see an empty store each time. Without DI, the global `_store` accumulates state across all tests in a test run — counts are wrong, isolation is impossible, and tests are order-dependent.

The `yield _store` in normal operation yields the same shared dict to every request (correct in-process behaviour). In tests, the override replaces that with a fresh dict per test. Same dependency function, different behavior depending on who overrides it.

**REFACTOR 2: `pydantic-settings`.**
`BaseSettings` reads from environment variables automatically. A field with no default (`database_url: str`) causes an immediate `ValidationError` at startup if the env var is missing — not a `KeyError` at first use at 3 AM under load. Fields with defaults (`app_name: str = "Task API"`) are optional and override-able via `APP_NAME=...` in the environment or a `.env` file.

**REFACTOR 3: `APIRouter(prefix="/tasks")`.**
Decoupling routes from `app` means the router can be mounted at a different prefix, versioned (`/v2/tasks`), or conditionally excluded without touching route functions. It also enables applying a shared `dependencies=[Depends(require_auth)]` to every route in the router at include time, not at each decorator.

## The isolation test — how it catches the global store

```python
store_a = {}
app.dependency_overrides[get_db] = lambda: iter([store_a])
client_a = TestClient(app)
client_a.post("/tasks", json={"title": "Leaked?", "done": False})

store_b = {}
app.dependency_overrides[get_db] = lambda: iter([store_b])
client_b = TestClient(app)
r = client_b.get("/tasks")
assert len(r.json()) == 0
```

With correct DI: `client_a`'s POST writes to `store_a`. `client_b`'s GET reads from `store_b` (fresh). Zero tasks — test passes.
Without DI: `client_a`'s POST writes to `_store`. `client_b`'s GET reads from `_store`. One task — test fails.

The override key must be the exact `get_db` function object. If `main.py` defines `get_db` and the test imports it with `from main import get_db`, the key is identical. A re-import from a different path creates a different object and the override silently does nothing.
