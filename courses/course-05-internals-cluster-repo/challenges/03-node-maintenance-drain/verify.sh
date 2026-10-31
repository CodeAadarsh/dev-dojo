#!/usr/bin/env bash
# Verifier for "Drain Without Downtime". Inspects live cluster state; prints the
# flag only when a worker has been cordoned, its app pods evicted, and the app
# stayed available. Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-maint
FLAG='KUBE{cordon_then_drain_no_downtime}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get deploy web >/dev/null 2>&1 || fail "Deployment 'web' not found in $NS — run setup.sh"

# 1. Find a cordoned WORKER node (control-plane does not count).
CORDONED=""
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  case "$node" in
    *control-plane*) continue ;;
  esac
  UNSCHED=$(kubectl get node "$node" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)
  if [ "$UNSCHED" = "true" ]; then
    CORDONED="$node"
    break
  fi
done
[ -n "$CORDONED" ] || fail "no worker node is cordoned (SchedulingDisabled) — did you 'kubectl cordon' a worker?"

# 2. The Deployment must still have >= 2 Ready replicas (PDB respected).
READY=$(kubectl -n "$NS" get deploy web -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${READY:-0}" -ge 2 ] 2>/dev/null; then
  fail "Deployment 'web' has fewer than 2 Ready replicas (found: ${READY:-0}) — the drain dropped you below the budget"
fi

# 3. No Running app pod may remain on the cordoned node (drain must have evicted them).
REMAIN=$(kubectl -n "$NS" get pods -l app=maint \
  --field-selector "spec.nodeName=${CORDONED},status.phase=Running" \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
[ -z "$REMAIN" ] || fail "app pods are still Running on cordoned node '$CORDONED': $REMAIN — run 'kubectl drain'"

echo "✓ cordoned worker node     : $CORDONED (SchedulingDisabled)"
echo "✓ deployment Ready replicas : $READY (>= 2, budget respected)"
echo "✓ app pods on drained node  : none remaining"
echo
echo "You moved a node out of rotation without dropping the app. Submit this flag in the platform:"
echo
echo "    $FLAG"
