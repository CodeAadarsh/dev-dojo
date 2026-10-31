#!/usr/bin/env bash
# Verifier for "No Endpoints, No Service". Passes only when Service 'api' in
# dojo-endpoints is backed by real app=api pod IPs via its EndpointSlice.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-endpoints
FLAG='KUBE{service_selector_must_match_pod_labels}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get svc api >/dev/null 2>&1 || fail "Service 'api' not found in $NS"

PORT=$(kubectl -n "$NS" get svc api -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
[ "$PORT" = "80" ] || fail "Service 'api' must expose port 80 (found: ${PORT:-unset})"

# The modern source of truth: EndpointSlice addresses backing this Service.
EPS_ADDRS=$(kubectl -n "$NS" get endpointslices -l kubernetes.io/service-name=api \
  -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>/dev/null)
# Fall back to the legacy Endpoints object if slices aren't readable.
if [ -z "$EPS_ADDRS" ]; then
  EPS_ADDRS=$(kubectl -n "$NS" get endpoints api -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
fi
[ -n "$EPS_ADDRS" ] || fail "Service 'api' has ZERO endpoints — its selector still matches no Ready pods"

# The addresses must be the real app=api pod IPs, not a hand-faked Endpoints object.
POD_IPS=$(kubectl -n "$NS" get pods -l app=api -o jsonpath='{.items[*].status.podIP}' 2>/dev/null)
[ -n "$POD_IPS" ] || fail "no app=api pods have an IP yet — are the backend pods Running and Ready?"

MATCHED=""
for a in $EPS_ADDRS; do
  for ip in $POD_IPS; do
    [ "$a" = "$ip" ] && MATCHED="$a"
  done
done
[ -n "$MATCHED" ] || fail "Service endpoints ($EPS_ADDRS) don't match any app=api pod IP — fix the selector, don't fake the Endpoints"

COUNT=$(printf '%s\n' $EPS_ADDRS | grep -c .)

echo "✓ Service 'api' exists     : yes"
echo "✓ Service port             : $PORT"
echo "✓ endpoint addresses       : $EPS_ADDRS"
echo "✓ endpoints count          : $COUNT"
echo "✓ backed by real pod IPs   : yes (e.g. $MATCHED)"
echo
echo "The Service now routes to live pods. Submit this flag in the platform:"
echo
echo "    $FLAG"
