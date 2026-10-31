#!/usr/bin/env bash
# Verifier for "Validate or Regret It".
# Runs the pytest harness in the work dir; prints flag only when all tests pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/04-validation-and-errors"
FLAG='KUBE{validate_early_fail_fast_json_envelope}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work dir $WORK not found — run setup.sh first"
cd "$WORK"

[ -f "app.py" ] || fail "app.py missing from $WORK"
[ -f "tests/test_harness.py" ] || fail "tests/test_harness.py missing — re-run setup.sh"

command -v python3 >/dev/null 2>&1 || fail "python3 not found"

if [ -d ".venv" ]; then
  source .venv/bin/activate
fi

python3 -c "import flask, pytest" 2>/dev/null || \
  fail "flask or pytest not installed — run: python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt"

python3 -m pytest tests/test_harness.py -v || fail "harness tests failed — fix app.py and retry"

echo
echo "All validation and error-handling checks passed. Submit this flag:"
echo
echo "    $FLAG"
