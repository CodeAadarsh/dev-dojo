#!/usr/bin/env bash
# Verifier for "Notes CRUD with SQLAlchemy".
# Runs the pytest harness in the work directory; prints the flag only when all
# eight tests pass. Exit 0 = solved, 1 = not yet.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/02-sqlalchemy-crud"
FLAG='KUBE{sqlalchemy_models_are_just_tables_in_disguise}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]              || fail "work dir $WORK not found — run setup.sh first"
[ -f "$WORK/app.py" ]       || fail "app.py missing — re-run setup.sh"
[ -f "$WORK/tests/test_harness.py" ] || fail "tests/test_harness.py missing — re-run setup.sh"

cd "$WORK"

command -v python3 >/dev/null 2>&1 || fail "python3 not found"

if [ -d ".venv" ]; then
    source .venv/bin/activate 2>/dev/null || true
fi

python3 -c "import flask, pytest, flask_sqlalchemy" 2>/dev/null || \
    fail "flask, pytest, or flask-sqlalchemy not installed — activate venv and: pip install flask pytest flask-sqlalchemy"

python3 -m pytest tests/test_harness.py -v || \
    fail "harness tests failed — fix your implementation and retry"

echo
echo "All SQLAlchemy CRUD checks passed. Submit this flag:"
echo
echo "    $FLAG"
