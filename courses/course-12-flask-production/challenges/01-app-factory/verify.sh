#!/usr/bin/env bash
# Verifier for "The App Factory".
# Runs the pytest harness in the work directory; prints the flag only when all
# six tests pass. Exit 0 = solved, 1 = not yet.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/01-app-factory"
FLAG='KUBE{app_factory_separates_config_from_code}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]              || fail "work dir $WORK not found — run setup.sh first"
[ -f "$WORK/app/__init__.py" ] || fail "app/__init__.py missing — re-run setup.sh"
[ -f "$WORK/app/views.py" ]    || fail "app/views.py missing — re-run setup.sh"
[ -f "$WORK/tests/test_harness.py" ] || fail "tests/test_harness.py missing — re-run setup.sh"

cd "$WORK"

command -v python3 >/dev/null 2>&1 || fail "python3 not found"

if [ -d ".venv" ]; then
    source .venv/bin/activate 2>/dev/null || true
fi

python3 -c "import flask, pytest" 2>/dev/null || \
    fail "flask or pytest not installed — activate venv and: pip install flask pytest"

python3 -m pytest tests/test_harness.py -v || \
    fail "harness tests failed — fix your implementation and retry"

echo
echo "All app-factory checks passed. Submit this flag:"
echo
echo "    $FLAG"
