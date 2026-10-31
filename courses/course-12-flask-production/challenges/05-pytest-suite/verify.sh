#!/usr/bin/env bash
# Verifier for "Test the App You Didn't Write".
# Meta-check: required test function names exist in the file, then runs pytest.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/05-pytest-suite"
FLAG='KUBE{tests_are_documentation}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work dir $WORK not found — run setup.sh first"
cd "$WORK"

[ -f "tests/test_app.py" ] || fail "tests/test_app.py missing — run setup.sh first"

REQUIRED_TESTS="
test_health_returns_200
test_health_body
test_create_task_returns_201
test_create_task_has_id
test_get_task_returns_200
test_get_missing_task_returns_404
"

echo "Checking required test function names..."
for fn in $REQUIRED_TESTS; do
    grep -q "def ${fn}" tests/test_app.py || fail "required function 'def ${fn}' not found in tests/test_app.py"
done
echo "  all six function names present"
echo

command -v python3 >/dev/null 2>&1 || fail "python3 not found"

if [ -d ".venv" ]; then
    source .venv/bin/activate
fi

python3 -c "import flask, pytest" 2>/dev/null || \
    fail "flask or pytest not installed — run: python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt"

echo "Running pytest..."
python3 -m pytest tests/test_app.py -v || fail "tests failed — fix your test implementations and retry"

echo
echo "All checks passed. Submit this flag:"
echo
echo "    $FLAG"
