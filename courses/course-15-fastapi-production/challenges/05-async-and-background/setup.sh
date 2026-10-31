#!/usr/bin/env bash
# Plants the "Async & Background Tasks" starter project.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/05-async-and-background"
mkdir -p "$WORK/tests"

# ── main.py skeleton ─────────────────────────────────────────────────────────
cat > "$WORK/main.py" << 'PYEOF'
# main.py — async + background tasks skeleton
# Three TODOs:
#   1. Fix the async endpoint so it uses asyncio.sleep() not time.sleep().
#   2. Wrap _slow_sync_lookup with run_in_executor so it doesn't block the loop.
#   3. Implement _record_notification so it appends to _notifications.
import asyncio
import time
from typing import List

from fastapi import BackgroundTasks, FastAPI
from pydantic import BaseModel

app = FastAPI()

# In-memory side-effect store — the verifier reads this via GET /notifications.
_notifications: List[dict] = []


class NotifyRequest(BaseModel):
    email: str
    message: str


def _slow_sync_lookup(email: str) -> str:
    # Simulates a blocking I/O call (legacy SDK, sync ORM, etc.).
    # Do NOT change this function — wrap it at the call site instead.
    time.sleep(0)   # zero duration so tests are fast; the blocking pattern is what matters
    return f"uid-for-{email}"


def _record_notification(email: str, message: str, uid: str) -> None:
    # TODO: append {"email": email, "message": message, "uid": uid} to _notifications.
    pass


@app.post("/notify", status_code=202)
async def notify(req: NotifyRequest, background_tasks: BackgroundTasks):
    # TODO (1): replace any direct time.sleep() with asyncio.sleep() if you add
    #            any artificial delay for testing purposes.
    # TODO (2): call _slow_sync_lookup via run_in_executor so it doesn't block
    #            the event loop:
    #              loop = asyncio.get_running_loop()
    #              uid = await loop.run_in_executor(None, _slow_sync_lookup, req.email)
    # TODO (3): add _record_notification as a BackgroundTask (it will run after
    #            the response is sent):
    #              background_tasks.add_task(_record_notification, req.email, req.message, uid)
    raise NotImplementedError


@app.get("/notifications")
async def list_notifications():
    return _notifications
PYEOF

# ── tests/__init__.py ─────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

# ── tests/test_sample.py — visible smoke test ─────────────────────────────────
cat > "$WORK/tests/test_sample.py" << 'PYEOF'
# Visible sample test — run locally to check the happy path.
# The verifier also runs hidden tests for side-effect observability and the
# async/sync pitfall.
import time
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_notify_returns_202():
    r = client.post("/notify", json={"email": "alice@example.com", "message": "hello"})
    assert r.status_code == 202, f"expected 202, got {r.status_code}: {r.text}"
    assert r.json().get("status") == "queued", f"body: {r.json()}"


def test_background_task_fires():
    client.post("/notify", json={"email": "bob@example.com", "message": "ping"})
    r = client.get("/notifications")
    assert r.status_code == 200
    emails = [n["email"] for n in r.json()]
    assert "bob@example.com" in emails, f"notification not recorded: {r.json()}"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement the three TODO sections in main.py:"
echo "                 1. Use run_in_executor to wrap _slow_sync_lookup."
echo "                 2. Schedule _record_notification as a BackgroundTask."
echo "                 3. Return 202 with {\"status\": \"queued\"}."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install fastapi 'uvicorn[standard]' httpx pytest pydantic"
echo
echo "Smoke test     : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag  : bash courses/course-15-fastapi-production/challenges/05-async-and-background/verify.sh"
