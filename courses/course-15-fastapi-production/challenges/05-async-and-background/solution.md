# Solution — Async & Background Tasks

Three changes to `main.py`: implement `_record_notification`, fix the async endpoint to use `run_in_executor`, and schedule the background task.

```python
import asyncio
import time
from typing import List

from fastapi import BackgroundTasks, FastAPI
from pydantic import BaseModel

app = FastAPI()

_notifications: List[dict] = []


class NotifyRequest(BaseModel):
    email: str
    message: str


def _slow_sync_lookup(email: str) -> str:
    time.sleep(0)
    return f"uid-for-{email}"


def _record_notification(email: str, message: str, uid: str) -> None:
    _notifications.append({"email": email, "message": message, "uid": uid})


@app.post("/notify", status_code=202)
async def notify(req: NotifyRequest, background_tasks: BackgroundTasks):
    loop = asyncio.get_running_loop()
    uid = await loop.run_in_executor(None, _slow_sync_lookup, req.email)
    background_tasks.add_task(_record_notification, req.email, req.message, uid)
    return {"status": "queued"}


@app.get("/notifications")
async def list_notifications():
    return _notifications
```

## Why each piece matters

**`run_in_executor(None, _slow_sync_lookup, req.email)`.** `None` means "use the default `ThreadPoolExecutor`". The blocking call runs in a thread while the event loop continues handling other requests. The `await` suspends only *this coroutine*, not the loop. This is the standard bridge between synchronous libraries and an async event loop — every synchronous ORM call, blocking SDK, or `time.sleep` belongs here.

**`background_tasks.add_task(...)` vs `await`.** The response (`{"status": "queued"}`) is sent before `_record_notification` runs. This is the defining feature of background tasks: the caller gets a 202 instantly and the server processes asynchronously. If you had `await _record_notification(...)` instead, the response would be delayed until the function finished — identical behaviour to a synchronous handler.

**`_record_notification` is a plain `def`, not `async def`.** FastAPI runs plain `def` background tasks in a thread pool automatically. If you need the background task itself to do async I/O (e.g., send an HTTP request), make it `async def` and FastAPI will `await` it on the event loop instead.

**The static check for `time.sleep` inside `async def`.** This is the pattern that causes the latency cliff. The fix isn't "don't use blocking calls" — it's "wrap blocking calls at the boundary." Everything behind `run_in_executor` can be synchronous legacy code; the wrapper is all that changes.

## Attacker's view / hardening preview

Background tasks that write to a shared in-memory list are fine for a lab. In production:

- Use a real task queue (Celery + Redis, or Dramatiq) so background work survives process restarts.
- Never mutate a module-level list from a background task without a lock — Python's GIL protects individual list operations but not multi-step read-modify-write sequences.
- Enforce a maximum queue depth and return 429 when exceeded, or callers will happily POST 10,000 notifications and fill your heap.
