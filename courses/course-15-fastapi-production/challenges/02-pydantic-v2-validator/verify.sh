#!/usr/bin/env bash
# Verifier for "Pydantic v2 Validator".
# Runs the pytest harness in the work directory; prints the flag only when all
# seven tests pass. Exit 0 = solved, 1 = not yet.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/02-pydantic-v2-validator"
FLAG='KUBE{validators_catch_what_types_miss}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]                        || fail "work directory missing — run setup.sh first"
[ -f "$WORK/main.py" ]                || fail "main.py not found in $WORK"
[ -f "$WORK/tests/test_bookings.py" ] || fail "tests/test_bookings.py not found — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install fastapi 'uvicorn[standard]' httpx pytest pydantic"
fi

if $PYTEST tests/ -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix main.py and retry"
fi
