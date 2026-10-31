#!/usr/bin/env bash
# Verifier for "Spot the Bottleneck".
# Checks that findings.txt names the bottleneck and the fix, then prints the flag.
set -uo pipefail

SLUG="06-spot-the-bottleneck"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{read_replica_fixes_the_bottleneck}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/findings.txt" ] || fail "findings.txt not found in $WORK — run setup.sh first"

# Check that TODO placeholders have been removed
grep -q "TODO" "$WORK/findings.txt" && \
  fail "findings.txt still has TODO placeholders — complete all four sections"

# Check that the fix mentions read replicas
grep -qi "replica" "$WORK/findings.txt" || \
  fail "'replica' not found — your fix must mention read replicas (case-insensitive)"

# Check that the bottleneck component is identified
grep -qi "primary\|single.*db\|single.*database\|single.*postgres\|single.*node\|db.01" "$WORK/findings.txt" || \
  fail "bottleneck not clearly identified — mention 'primary', 'single DB/node', or 'db-01'"

echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
