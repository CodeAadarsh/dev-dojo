#!/usr/bin/env bash
# Verifier for "Kill and Heal".
# Checks: spec.replicas >= 3 AND readyReplicas == spec.replicas AND all pods RS-owned.
set -uo pipefail

NS=dojo-chaos
FLAG='KUBE{controllers_heal_what_chaos_kills}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' missing — run setup.sh first"
kubectl -n "$NS" get deploy web >/dev/null 2>&1 || fail "Deployment 'web' not found in $NS — run setup.sh"

SPEC=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.replicas}' 2>/dev/null)
READY=$(kubectl -n "$NS" get deploy web -o jsonpath='{.status.readyReplicas}' 2>/dev/null)

if ! [ "${SPEC:-0}" -ge 3 ] 2>/dev/null; then
  fail "Deployment 'web' spec.replicas must be >= 3 (found: ${SPEC:-0})"
fi

if ! [ "${READY:-0}" -ge "${SPEC:-3}" ] 2>/dev/null; then
  fail "Healing incomplete: readyReplicas=${READY:-0}, spec.replicas=${SPEC:-3}. Wait for the controller — run: kubectl -n $NS rollout status deploy/web"
fi

# Count pods owned by a ReplicaSet (controller-managed)
RS_OWNED=0
for owner_kind in $(kubectl -n "$NS" get pods \
    -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null); do
  [ "$owner_kind" = "ReplicaSet" ] && RS_OWNED=$((RS_OWNED + 1)) || true
done

if ! [ "$RS_OWNED" -ge "${SPEC:-3}" ] 2>/dev/null; then
  fail "Found $RS_OWNED ReplicaSet-owned pods but need >= ${SPEC:-3}. Manually-created pods (kubectl run) don't count — the controller must own them."
fi

echo "✓ spec.replicas             : $SPEC"
echo "✓ readyReplicas             : $READY  (fully healed)"
echo "✓ ReplicaSet-owned pods     : $RS_OWNED"
echo
echo "The controller healed the cluster. Submit this flag in the platform:"
echo
echo "    $FLAG"
