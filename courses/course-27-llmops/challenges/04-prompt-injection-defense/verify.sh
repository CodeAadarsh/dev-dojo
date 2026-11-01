#!/usr/bin/env bash
# Verifier for "Prompt Injection Defense".
# Runs the pytest harness in the work directory; prints the flag only when
# all eight tests pass.  Exit 0 = solved, 1 = not yet.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/04-prompt-injection-defense"
FLAG='KUBE{trust_boundaries_block_injection}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]              || fail "work directory missing — run setup.sh first"
[ -f "$WORK/defender.py" ]  || fail "defender.py not found — run setup.sh first"
[ -f "$WORK/tests/test_defense.py" ] || fail "tests/test_defense.py missing — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

if $PYTEST tests/ -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix defender.py and retry"
fi
