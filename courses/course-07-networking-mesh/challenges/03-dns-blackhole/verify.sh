#!/usr/bin/env bash
# Verifier for "DNS Blackhole".
# Checks that api-svc in dojo-dns has at least one ready Endpoint.
set -uo pipefail

NS=dojo-dns
FLAG='KUBE{dns_resolves_but_endpoints_dont_lie}'

fail() { echo "x $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

kubectl -n "$NS" get svc api-svc >/dev/null 2>&1 \
  || fail "Service 'api-svc' not found in $NS"

kubectl -n "$NS" get endpoints api-svc >/dev/null 2>&1 \
  || fail "Endpoints object for 'api-svc' not found (API server should auto-create it)"

# Pull the subsets/addresses — non-empty means at least one ready backend
ADDRS=$(kubectl -n "$NS" get endpoints api-svc \
  -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)

[ -n "$ADDRS" ] \
  || fail "Service 'api-svc' still has no ready Endpoints (selector or targetPort still wrong)"

# Also confirm the Service selector now matches version=v2
SVC_VERSION=$(kubectl -n "$NS" get svc api-svc \
  -o jsonpath='{.spec.selector.version}' 2>/dev/null)
[ "$SVC_VERSION" = "v2" ] \
  || fail "Service selector 'version' must be 'v2' to match the running pod (found: '${SVC_VERSION:-unset}')"

# Confirm targetPort is now 80
TARGET_PORT=$(kubectl -n "$NS" get svc api-svc \
  -o jsonpath='{.spec.ports[0].targetPort}' 2>/dev/null)
[ "$TARGET_PORT" = "80" ] \
  || fail "Service ports[0].targetPort must be 80 (found: '${TARGET_PORT:-unset}')"

echo "v api-svc selector version  : v2"
echo "v api-svc targetPort        : 80"
echo "v Endpoints (ready IPs)     : $ADDRS"
echo
echo "All endpoint checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
