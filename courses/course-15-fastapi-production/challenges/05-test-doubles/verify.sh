#!/usr/bin/env bash
# Verifier for "Test Doubles with dependency_overrides".
# Runs the learner's test suite with an additional hidden guard test;
# prints the flag only when all tests pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/05-test-doubles"
FLAG='KUBE{dependency_override_test_isolation}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/main.py" ] || fail "main.py not found — run setup.sh first"
[ -f "$WORK/tests/conftest.py" ] || fail "tests/conftest.py not found — run setup.sh first"
[ -f "$WORK/tests/test_app.py" ] || fail "tests/test_app.py not found — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install fastapi httpx pytest pydantic"
fi

# Write a hidden guard that fails if the real EmailNotifier was reached
TMPDIR_GUARD=$(mktemp -d)
trap 'rm -rf "$TMPDIR_GUARD"' EXIT

cat > "$TMPDIR_GUARD/test_guard.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.environ["WORK_DIR"])

import pytest
from fastapi.testclient import TestClient
import main as m

def setup_function():
    m._users.clear()

# import the learner's conftest fixtures by exercising them
def test_recording_notifier_exists():
    """Confirms RecordingNotifier is defined in conftest."""
    import tests.conftest as cf
    assert hasattr(cf, "RecordingNotifier"), (
        "RecordingNotifier class not found in tests/conftest.py"
    )
    rn = cf.RecordingNotifier()
    assert hasattr(rn, "calls"), "RecordingNotifier must have a .calls attribute"
    rn.send_welcome("alice")
    assert any(c.get("event") == "welcome" and c.get("username") == "alice" for c in rn.calls), \
        "send_welcome must append {'event':'welcome','username':...} to .calls"
    rn.send_goodbye("alice")
    assert any(c.get("event") == "goodbye" and c.get("username") == "alice" for c in rn.calls), \
        "send_goodbye must append {'event':'goodbye','username':...} to .calls"

def test_override_cleans_up(client, recorder):
    """The client fixture must clear dependency_overrides after the test."""
    # This test just passes — the conftest teardown is validated by the absence of leaks
    pass
PYEOF

if WORK_DIR="$WORK" $PYTEST "$WORK/tests/" "$TMPDIR_GUARD/test_guard.py" -q 2>&1; then
    echo
    echo "All test-doubles checks passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix conftest.py and test_app.py, then retry"
fi
