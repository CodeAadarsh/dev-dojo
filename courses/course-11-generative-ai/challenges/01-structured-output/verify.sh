#!/usr/bin/env bash
# Verifier for "Structured Output".
# Runs the pytest harness; prints the flag only when all tests pass.
set -uo pipefail

SLUG="01-structured-output"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{schema_validation_makes_llm_outputs_predictable}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work dir $WORK missing — run setup.sh first"
[ -f "$WORK/solution.py" ] || fail "solution.py not found in $WORK"
[ -f "$WORK/test_solution.py" ] || fail "test_solution.py missing — was WORK dir modified?"

if [ -f "$WORK/.venv/bin/pytest" ]; then
  PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
  PYTEST="pytest"
else
  fail "pytest not found — run: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

cd "$WORK"
"$PYTEST" test_solution.py -v --tb=short || fail "one or more tests failed — fix solution.py and retry"

echo
echo "All schema tests passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
