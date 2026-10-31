#!/usr/bin/env bash
# Verifier for "Expose Me". Inspects live cluster state; prints the flag only
# when a ClusterIP Service selects app=shop on port 80 AND has ready endpoints.
# Exit 0 = solved, 1 = not yet. Uses only kubectl + POSIX tools (no jq).
set -uo pipefail

NS=dojo-expose
FLAG='KUBE{clusterip_needs_ready_endpoints}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get deploy shop >/dev/null 2>&1 || fail "Deployment 'shop' not found in $NS — run setup.sh first"

SVCS=$(kubectl -n "$NS" get svc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
[ -n "$SVCS" ] || fail "no Service exists in $NS — create a ClusterIP Service selecting app=shop on port 80"

# Find a Service whose selector is app=shop and that serves on port 80.
MATCH=""
for svc in $SVCS; do
  SEL=$(kubectl -n "$NS" get svc "$svc" -o jsonpath='{.spec.selector.app}' 2>/dev/null)
  PORTS=$(kubectl -n "$NS" get svc "$svc" -o jsonpath='{.spec.ports[*].port}' 2>/dev/null)
  if [ "$SEL" = "shop" ] && printf ' %s ' "$PORTS" | grep -q ' 80 '; then
    MATCH="$svc"
    break
  fi
done
[ -n "$MATCH" ] || fail "no Service selects app=shop on port 80 (services found: $SVCS) — check .spec.selector.app and .spec.ports[].port"

PORTS=$(kubectl -n "$NS" get svc "$MATCH" -o jsonpath='{.spec.ports[*].port}' 2>/dev/null)

# Ready endpoints: prefer the legacy Endpoints object, fall back to EndpointSlices.
EPIPS=$(kubectl -n "$NS" get endpoints "$MATCH" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
if [ -z "$EPIPS" ]; then
  EPIPS=$(kubectl -n "$NS" get endpointslices -l "kubernetes.io/service-name=$MATCH" -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>/dev/null)
fi
[ -n "$EPIPS" ] || fail "Service '$MATCH' has NO ready endpoints — the selector matched no Ready pods. Check the pod labels and that the shop pods are Running and Ready."

NEP=$(printf '%s' "$EPIPS" | wc -w | tr -d ' ')

echo "✓ Service present          : $MATCH"
echo "✓ selector                 : app=shop"
echo "✓ port                     : 80 (service ports: $PORTS)"
echo "✓ ready endpoints          : $NEP ($EPIPS)"
echo
echo "The Service exists AND routes to ready pods. Submit this flag in the platform:"
echo
echo "    $FLAG"
