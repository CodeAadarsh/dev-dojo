#!/usr/bin/env bash
# Verifier for "Helm Chart with Values Override".
# Checks: release 'portal' in dojo-helm2, Deployment has 2 replicas + nginx image.
set -uo pipefail

NS=dojo-helm2
FLAG='KUBE{helm_values_drive_release}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' not found — run setup.sh first"

command -v helm >/dev/null 2>&1 || fail "helm not found on PATH"

RELEASES=$(helm -n "$NS" list -q 2>/dev/null)
echo "$RELEASES" | grep -q '^portal$' \
  || fail "helm release 'portal' not found in $NS (found: ${RELEASES:-<none>})"

DEPLOY=$(kubectl -n "$NS" get deploy \
  -l "app.kubernetes.io/instance=portal" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$DEPLOY" ] || fail "no Deployment with label app.kubernetes.io/instance=portal in $NS"

REPLICAS=$(kubectl -n "$NS" get deploy "$DEPLOY" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null)
[ "$REPLICAS" = "2" ] || fail "Deployment '$DEPLOY' needs spec.replicas=2 (found: ${REPLICAS:-unset})"

READY=$(kubectl -n "$NS" get deploy "$DEPLOY" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${READY:-0}" -ge 2 ] 2>/dev/null; then
  fail "fewer than 2 replicas are Ready (found: ${READY:-0}) — wait for rollout or check pod logs"
fi

IMAGE=$(kubectl -n "$NS" get deploy "$DEPLOY" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
case "$IMAGE" in
  nginx*) ;;
  *) fail "container image must start with 'nginx' (found: ${IMAGE:-none})" ;;
esac

helm -n "$NS" list -f '^portal$' 2>/dev/null | grep -q 'deployed' \
  || fail "helm release 'portal' is not in 'deployed' state — check 'helm -n $NS list'"

echo "✓ helm release           : portal (deployed)"
echo "✓ Deployment             : $DEPLOY"
echo "✓ replicas spec          : $REPLICAS"
echo "✓ replicas ready         : $READY"
echo "✓ container image        : $IMAGE"
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
