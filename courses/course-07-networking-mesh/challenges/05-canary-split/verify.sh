#!/usr/bin/env bash
# Verifier for "Canary Traffic Split".
# Checks VirtualService 'app' has two weighted routes summing to 100 AND
# DestinationRule 'app' has at least two subsets. Prints flag on success.
set -uo pipefail

NS=dojo-canary
FLAG='KUBE{canary_split_virtual_service}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

kubectl get crd virtualservices.networking.istio.io >/dev/null 2>&1 \
  || fail "Istio CRDs not found — install Istio before attempting this challenge"

kubectl get crd destinationrules.networking.istio.io >/dev/null 2>&1 \
  || fail "Istio CRDs not found — install Istio before attempting this challenge"

# Check VirtualService exists
kubectl -n "$NS" get virtualservice app >/dev/null 2>&1 \
  || fail "VirtualService 'app' not found in $NS"

# Check DestinationRule exists
kubectl -n "$NS" get destinationrule app >/dev/null 2>&1 \
  || fail "DestinationRule 'app' not found in $NS"

# Extract the two weights from the VirtualService
WEIGHT0=$(kubectl -n "$NS" get virtualservice app \
  -o jsonpath='{.spec.http[0].route[0].weight}' 2>/dev/null)
WEIGHT1=$(kubectl -n "$NS" get virtualservice app \
  -o jsonpath='{.spec.http[0].route[1].weight}' 2>/dev/null)

[ -n "$WEIGHT0" ] || fail "VirtualService 'app' has no http[0].route[0].weight — ensure two weighted destinations exist"
[ -n "$WEIGHT1" ] || fail "VirtualService 'app' has no http[0].route[1].weight — ensure two weighted destinations exist"

SUM=$((WEIGHT0 + WEIGHT1))
[ "$SUM" -eq 100 ] \
  || fail "route weights sum to $SUM (must be exactly 100; got $WEIGHT0 + $WEIGHT1)"

# Check DestinationRule has at least two subsets
SUBSET0=$(kubectl -n "$NS" get destinationrule app \
  -o jsonpath='{.spec.subsets[0].name}' 2>/dev/null)
SUBSET1=$(kubectl -n "$NS" get destinationrule app \
  -o jsonpath='{.spec.subsets[1].name}' 2>/dev/null)

[ -n "$SUBSET0" ] || fail "DestinationRule 'app' must define at least two subsets (subsets[0] missing)"
[ -n "$SUBSET1" ] || fail "DestinationRule 'app' must define at least two subsets (subsets[1] missing)"

echo "✓ VirtualService 'app' found in $NS"
echo "✓ Route weights                 : $WEIGHT0 + $WEIGHT1 = $SUM (sums to 100)"
echo "✓ DestinationRule 'app' found   : subsets '$SUBSET0' and '$SUBSET1'"
echo
echo "All canary split checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
