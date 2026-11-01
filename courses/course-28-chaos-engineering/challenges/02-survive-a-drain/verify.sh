#!/usr/bin/env bash
# Verifier for "Survive a Drain".
# Checks: at least one worker cordoned + PDB exists + readyReplicas >= PDB minAvailable.
set -uo pipefail

NS=dojo-chaos
FLAG='KUBE{pdb_is_your_drain_insurance}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' missing — run setup.sh first"
kubectl -n "$NS" get deploy web >/dev/null 2>&1 || fail "Deployment 'web' not found in $NS — run setup.sh"

# Check at least one non-control-plane node is cordoned (spec.unschedulable == true)
CORDONED=0
while IFS= read -r line; do
  case "$line" in
    *control-plane*) ;;
    *"true"*) CORDONED=$((CORDONED + 1)) ;;
  esac
done < <(kubectl get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.unschedulable}{"\n"}{end}' 2>/dev/null)

if ! [ "$CORDONED" -ge 1 ] 2>/dev/null; then
  fail "No worker node is SchedulingDisabled. Drain a worker first: kubectl drain <node> --ignore-daemonsets --delete-emptydir-data"
fi

# Check PDB exists in the namespace
PDB_NAME=$(kubectl -n "$NS" get pdb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "${PDB_NAME:-}" ] || fail "No PodDisruptionBudget found in '$NS' — add one with minAvailable: 2 targeting app=web"

# Get current readyReplicas
READY=$(kubectl -n "$NS" get deploy web -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
SPEC=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.replicas}' 2>/dev/null)

# Extract minAvailable (integer field) and verify readyReplicas meets it
MIN_AVAIL=$(kubectl -n "$NS" get pdb "$PDB_NAME" -o jsonpath='{.spec.minAvailable}' 2>/dev/null)

if echo "${MIN_AVAIL:-}" | grep -qE '^[0-9]+$' 2>/dev/null; then
  if ! [ "${READY:-0}" -ge "$MIN_AVAIL" ] 2>/dev/null; then
    fail "readyReplicas (${READY:-0}) < PDB minAvailable ($MIN_AVAIL). The drain may still be in progress, or eviction violated the budget. Check: kubectl -n $NS get pods"
  fi
else
  if ! [ "${READY:-0}" -ge 1 ] 2>/dev/null; then
    fail "No Ready pods in '$NS' after the drain — the PDB did not protect availability"
  fi
fi

echo "✓ cordoned worker nodes     : $CORDONED"
echo "✓ PDB name                  : $PDB_NAME"
echo "✓ PDB minAvailable          : ${MIN_AVAIL:-(maxUnavailable variant)}"
echo "✓ readyReplicas             : ${READY:-?} / $SPEC"
echo
echo "The drain completed without violating the disruption budget. Submit this flag:"
echo
echo "    $FLAG"
