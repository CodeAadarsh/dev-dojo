#!/usr/bin/env bash
# Verifier for "Imperative Speed Run". Inspects live cluster state; prints the
# flag only when the Deployment + Service are correct. Exit 0 = solved, 1 = not.
set -uo pipefail

NS=dojo-exam
FLAG='KUBE{imperative_speed_beats_the_clock}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get deploy speedy >/dev/null 2>&1 || fail "Deployment 'speedy' not found in $NS"

REPLICAS=$(kubectl -n "$NS" get deploy speedy -o jsonpath='{.spec.replicas}' 2>/dev/null)
if ! [ "${REPLICAS:-0}" -eq 3 ] 2>/dev/null; then
  fail "Deployment 'speedy' must have exactly 3 replicas (found: ${REPLICAS:-none})"
fi

IMAGE=$(kubectl -n "$NS" get deploy speedy -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
case "$IMAGE" in
  *nginx*) : ;;
  *) fail "container image must be an nginx image (found: ${IMAGE:-none})" ;;
esac

# The Deployment's pod selector label (kubectl create deploy uses app=<name>).
DAPP=$(kubectl -n "$NS" get deploy speedy -o jsonpath='{.spec.selector.matchLabels.app}' 2>/dev/null)
[ -n "$DAPP" ] || fail "Deployment 'speedy' has no 'app' pod label to select on"

# Find a Service in the namespace whose selector matches the Deployment AND
# that publishes port 80.
SVCS=$(kubectl -n "$NS" get svc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
[ -n "$SVCS" ] || fail "no Service found in $NS — expose the Deployment on port 80"

MATCH=""
for s in $SVCS; do
  SAPP=$(kubectl -n "$NS" get svc "$s" -o jsonpath='{.spec.selector.app}' 2>/dev/null)
  [ "$SAPP" = "$DAPP" ] || continue
  PORTS=$(kubectl -n "$NS" get svc "$s" -o jsonpath='{.spec.ports[*].port}' 2>/dev/null)
  for p in $PORTS; do
    if [ "$p" = "80" ]; then MATCH="$s"; break; fi
  done
  [ -n "$MATCH" ] && break
done

[ -n "$MATCH" ] || fail "no Service selects 'speedy' (app=$DAPP) on port 80 — use: kubectl -n $NS expose deploy speedy --port=80"

echo "✓ Deployment 'speedy'      : present"
echo "✓ replicas                 : $REPLICAS"
echo "✓ image                    : $IMAGE"
echo "✓ Service selecting speedy : $MATCH (app=$DAPP, port 80)"
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
