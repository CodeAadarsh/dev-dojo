# Async & Background Tasks — Side Effects You Can Observe

The payments team added a `/notify` endpoint that queues an email after processing a request. PR review comments: *"This endpoint blocks the event loop for 2 seconds on every call — measured in staging. Also, the background task runs but we can't tell if it actually fired because nothing's observable. And the blocking DB call was ported straight from the Flask version without async wrapping — it's deadlocking the worker under load."*

Your job: fix the async pitfall and implement a BackgroundTask whose side effect the verifier can assert.

## Context

`setup.sh` plants a project in your work directory:

```
~/.kube-dojo-work/05-async-and-background/
├── main.py          # FastAPI app — async/background skeleton with stubs
└── tests/
    └── test_sample.py   # visible smoke test for the happy path
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/05-async-and-background
python3 -m venv .venv && . .venv/bin/activate
pip install fastapi "uvicorn[standard]" httpx pytest pydantic
```

## Mission

Implement these behaviours in `main.py`:

| Scenario | Expected |
|----------|----------|
| `POST /notify` with `{"email": "x@y.com", "message": "hello"}` | **202** Accepted, body `{"status": "queued"}` |
| After the response, the background task fires and appends to `_notifications` list | `GET /notifications` returns the entry |
| The async endpoint does **not** call `time.sleep()` directly — it uses `asyncio.sleep()` | Non-blocking |
| A simulated slow sync call inside the endpoint is wrapped with `asyncio.run_in_executor` | Unblocked event loop |

The verifier runs hidden tests that:
1. POST to `/notify` and check the 202 + body shape.
2. Wait briefly then GET `/notifications` and assert the side effect is present.
3. Confirm no bare `time.sleep` call inside `async def` functions (static check via source inspection).

### Why background tasks, not just `await something()`

`await` still blocks the current *coroutine* until it finishes — the response isn't sent until the awaited call returns. `BackgroundTask` runs *after* the response is sent. Use it for any work the caller doesn't need to wait for: emails, audit logs, cache warming, webhook fires. The caller gets a 202 instantly; the side effect happens on the server at its own pace.

### The sync-in-async pitfall

```python
# Wrong — blocks the event loop, starves every concurrent request
async def get_user(user_id: int):
    return db_session.query(User).get(user_id)   # synchronous ORM call

# Right — offloads to a thread so the event loop keeps turning
import asyncio
async def get_user(user_id: int):
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, db_session.query(User).get, user_id)
```

The skeleton has a `_slow_sync_lookup` function that uses `time.sleep(0)` to simulate a blocking call. Wrap it with `run_in_executor` inside the async endpoint.

## Why this matters

FastAPI is ASGI — a single-threaded event loop handles all concurrent requests. One synchronous blocking call (`time.sleep`, a blocking socket, a non-async ORM call) pins the loop for its entire duration. During that time, zero other requests make progress. At low load it's invisible; at moderate load (20+ concurrent) it causes the latency cliff the payments team measured.

## Verify

```bash
bash courses/course-15-fastapi-production/challenges/05-async-and-background/verify.sh
```

All hidden scenarios green → flag printed.
