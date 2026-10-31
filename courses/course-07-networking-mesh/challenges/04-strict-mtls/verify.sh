#!/usr/bin/env bash
# Verifier for "Strict mTLS Enforcement".
# Checks that a PeerAuthentication named 'default' exists in dojo-mtls with
# spec.mtls.mode == STRICT and no workload selector. Prints flag on success.
set -uo pipefail

NS=dojo-mtls
FLAG='KUBE{strict_mtls_peer_authentication}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

kubectl get crd peerauthentications.security.istio.io >/dev/null 2>&1 \
  || fail "Istio CRDs not found — install Istio and run setup.sh first"

kubectl -n "$NS" get peerauthentication default >/dev/null 2>&1 \
  || fail "PeerAuthentication 'default' not found in $NS — author it and apply"

MODE=$(kubectl -n "$NS" get peerauthentication default \
  -o jsonpath='{.spec.mtls.mode}' 2>/dev/null)
[ "$MODE" = "STRICT" ] \
  || fail "spec.mtls.mode is '${MODE:-unset}' — must be STRICT"

SELECTOR=$(kubectl -n "$NS" get peerauthentication default \
  -o jsonpath='{.spec.selector}' 2>/dev/null)
[ -z "$SELECTOR" ] \
  || fail "PeerAuthentication has a selector set ('${SELECTOR}') — remove it to make this namespace-wide"

echo "✓ PeerAuthentication 'default' found in $NS"
echo "✓ spec.mtls.mode                : STRICT"
echo "✓ No workload selector          : namespace-wide policy"
echo
echo "All mTLS checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
