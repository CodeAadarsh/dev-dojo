#!/usr/bin/env bash
# Verifier for "Pagination & Status Codes".
# Runs the pytest harness; prints the flag only when all nine tests pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/02-pagination-and-status-codes"
FLAG='KUBE{status_codes_tell_the_truth}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/main.py" ] || fail "main.py not found in $WORK"
[ -f "$WORK/tests/test_api.py" ] || fail "tests/test_api.py not found — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install fastapi pytest httpx"
fi

if $PYTEST tests/ -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix your implementation and retry"
fi
