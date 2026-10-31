#!/usr/bin/env bash
# Verifier for "Gateway API Route".
# Checks that a correctly-wired Gateway + HTTPRoute exist in dojo-gw.
# Prints the flag only when every check passes.
set -uo pipefail

NS=dojo-gw
FLAG='KUBE{gateway_api_routes_the_new_ingress}'

fail() { echo "x $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

# Check Gateway CRDs exist
kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 \
  || fail "Gateway API CRDs not installed — kubectl apply -f the standard-install.yaml"

# Check Gateway named dojo-gw exists
kubectl -n "$NS" get gateway dojo-gw >/dev/null 2>&1 \
  || fail "Gateway 'dojo-gw' not found in $NS — create it (gateway.networking.k8s.io/v1)"

# Check Gateway has a gatewayClassName set
GWC=$(kubectl -n "$NS" get gateway dojo-gw -o jsonpath='{.spec.gatewayClassName}' 2>/dev/null)
[ -n "$GWC" ] || fail "Gateway 'dojo-gw' must have spec.gatewayClassName set"

# Check Gateway has at least one listener
GW_LISTENERS=$(kubectl -n "$NS" get gateway dojo-gw -o jsonpath='{.spec.listeners}' 2>/dev/null)
[ -n "$GW_LISTENERS" ] || fail "Gateway 'dojo-gw' must have at least one listener defined"

# Check HTTPRoute named web-route exists
kubectl -n "$NS" get httproute web-route >/dev/null 2>&1 \
  || fail "HTTPRoute 'web-route' not found in $NS — create it (gateway.networking.k8s.io/v1)"

# Check HTTPRoute has a parentRef to dojo-gw
PARENT_NAME=$(kubectl -n "$NS" get httproute web-route -o jsonpath='{.spec.parentRefs[0].name}' 2>/dev/null)
[ "$PARENT_NAME" = "dojo-gw" ] \
  || fail "HTTPRoute 'web-route' must have parentRefs[0].name = 'dojo-gw' (found: '${PARENT_NAME:-unset}')"

# Check HTTPRoute has a backendRef to web-svc
BACKEND_NAME=$(kubectl -n "$NS" get httproute web-route \
  -o jsonpath='{.spec.rules[0].backendRefs[0].name}' 2>/dev/null)
[ "$BACKEND_NAME" = "web-svc" ] \
  || fail "HTTPRoute 'web-route' spec.rules[0].backendRefs[0].name must be 'web-svc' (found: '${BACKEND_NAME:-unset}')"

# Check backendRef port is 80
BACKEND_PORT=$(kubectl -n "$NS" get httproute web-route \
  -o jsonpath='{.spec.rules[0].backendRefs[0].port}' 2>/dev/null)
[ "$BACKEND_PORT" = "80" ] \
  || fail "HTTPRoute backendRef port must be 80 (found: '${BACKEND_PORT:-unset}')"

echo "v Gateway 'dojo-gw' exists          : gatewayClassName=$GWC"
echo "v HTTPRoute 'web-route' exists       : parentRef -> dojo-gw"
echo "v backendRef                         : web-svc:80"
echo
echo "All Gateway API checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
