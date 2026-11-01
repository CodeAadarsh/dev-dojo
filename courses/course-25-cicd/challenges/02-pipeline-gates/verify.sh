#!/usr/bin/env bash
# Verifier for "Pipeline Gates".
# 1. Checks the Makefile has a ci: target.
# 2. Runs make ci and asserts exit 0 (all gates pass).
# 3. Injects an always-failing test and asserts make test exits non-zero.
# Prints the flag only when all three checks pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/02-pipeline-gates"
FLAG='KUBE{gates_must_gate}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/Makefile" ] || fail "Makefile not found in $WORK — run setup.sh first"
[ -f "$WORK/app.py" ] || fail "app.py not found in $WORK — run setup.sh first"

cd "$WORK"

# ── Check 1: ci target exists ─────────────────────────────────────────────────
grep -q '^ci:' Makefile || fail "Makefile has no 'ci:' target — add 'ci: lint test build'"

# ── Check 2: make ci exits 0 ──────────────────────────────────────────────────
echo "Running 'make ci' ..."
if ! make ci; then
    echo
    fail "'make ci' exited non-zero — fix app.py (the bug) and the test target first"
fi

# ── Check 3: gate actually gates ──────────────────────────────────────────────
# Inject a temp always-failing test; clean up via trap regardless of outcome
GATE_TEST="$WORK/tests/test_gate_check.py"
trap 'rm -f "$GATE_TEST"' EXIT

cat > "$GATE_TEST" << 'PYEOF'
def test_injected_gate_check_always_fails():
    assert False, "gate check injected by verifier — this must propagate"
PYEOF

echo "Checking that 'make test' propagates failures ..."
gate_caught=0
if ! make test > /dev/null 2>&1; then
    gate_caught=1
fi

rm -f "$GATE_TEST"
trap - EXIT

[ "$gate_caught" -eq 1 ] || fail "test gate swallows failures — remove '|| true' from the test: target in your Makefile"

echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
