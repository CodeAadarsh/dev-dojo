#!/usr/bin/env bash
# Verifier: the 'reports' Deployment in dojo-sched-fix is scheduled and Ready.
set -uo pipefail

NS=dojo-sched-fix
FLAG='KUBE{nodeselector_must_match_a_real_node_label}'
fail() { echo "✗ $1"; exit 1; }

kubectl -n "$NS" get deploy reports >/dev/null 2>&1 || fail "deployment 'reports' not found in $NS"

READY=$(kubectl -n "$NS" get deploy reports -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${READY:-0}" -ge 1 ] 2>/dev/null; then
  PEND=$(kubectl -n "$NS" get pods -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
  fail "'reports' still has no Ready pods (phases: ${PEND:-none}). Check 'describe pod' Events."
fi

echo "✓ 'reports' scheduled and Ready (readyReplicas=$READY)"
echo
echo "Submit this flag:"
echo
echo "    $FLAG"
