#!/usr/bin/env bash
# Verifier for "Async & Background Tasks".
# Runs a hidden pytest suite; prints the flag only when all checks pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/05-async-and-background"
FLAG='KUBE{background_side_effects_are_observable}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/main.py" ] || fail "main.py not found — run setup.sh first"

cd "$WORK"

if [ -d ".venv" ]; then
  source .venv/bin/activate
fi

python3 -c "import fastapi, pydantic" 2>/dev/null || \
  fail "dependencies missing — run: python3 -m venv .venv && . .venv/bin/activate && pip install fastapi 'uvicorn[standard]' httpx pytest pydantic"

# ── hidden test suite ─────────────────────────────────────────────────────────
HIDDEN_DIR="$(mktemp -d)"
trap 'rm -rf "$HIDDEN_DIR"' EXIT

cat > "$HIDDEN_DIR/test_hidden.py" << 'PYEOF'
import sys
import os
sys.path.insert(0, os.environ["WORK"])

import inspect
from fastapi.testclient import TestClient
import main as app_module
from main import app, _notifications

client = TestClient(app)


def _reset():
    _notifications.clear()


def test_notify_returns_202_with_queued():
    _reset()
    r = client.post("/notify", json={"email": "test@example.com", "message": "verify"})
    assert r.status_code == 202, f"expected 202, got {r.status_code}: {r.text}"
    body = r.json()
    assert body.get("status") == "queued", f"body must contain status=queued, got {body}"


def test_background_side_effect_is_observable():
    _reset()
    client.post("/notify", json={"email": "check@example.com", "message": "side-effect"})
    r = client.get("/notifications")
    assert r.status_code == 200
    entries = r.json()
    assert len(entries) >= 1, "background task did not append to _notifications"
    emails = [e.get("email") for e in entries]
    assert "check@example.com" in emails, f"expected check@example.com in notifications, got {emails}"


def test_notification_entry_has_required_fields():
    _reset()
    client.post("/notify", json={"email": "fields@example.com", "message": "check-fields"})
    entries = client.get("/notifications").json()
    entry = next((e for e in entries if e.get("email") == "fields@example.com"), None)
    assert entry is not None, "notification entry not found"
    assert "email" in entry and "message" in entry and "uid" in entry, \
        f"entry must have email, message, uid keys; got {entry}"


def test_no_bare_time_sleep_in_async_functions():
    source = inspect.getsource(app_module)
    lines = source.splitlines()
    in_async = False
    violations = []
    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith("async def "):
            in_async = True
        elif stripped.startswith("def ") and not stripped.startswith("async def "):
            in_async = False
        if in_async and "time.sleep(" in stripped and "run_in_executor" not in stripped:
            violations.append(f"line {i}: {line.rstrip()}")
    assert not violations, \
        "bare time.sleep() found inside async def — use asyncio.sleep() or run_in_executor:\n" + "\n".join(violations)


def test_run_in_executor_used_for_slow_sync():
    source = inspect.getsource(app_module)
    assert "run_in_executor" in source, \
        "run_in_executor not found in main.py — _slow_sync_lookup must be wrapped"


def test_multiple_notifications_accumulate():
    _reset()
    client.post("/notify", json={"email": "a@x.com", "message": "first"})
    client.post("/notify", json={"email": "b@x.com", "message": "second"})
    entries = client.get("/notifications").json()
    assert len(entries) >= 2, f"expected at least 2 notifications, got {len(entries)}"
PYEOF

export WORK="$WORK"
if python3 -m pytest "$HIDDEN_DIR/test_hidden.py" -v 2>&1; then
    echo
    echo "All async and background-task checks passed. Submit this flag:"
    echo
    echo "    $FLAG"
else
    fail "one or more hidden tests failed — check your implementation and retry"
fi
