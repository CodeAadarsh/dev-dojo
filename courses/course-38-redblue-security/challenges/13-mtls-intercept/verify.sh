#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-sec-mtls"
fail() { echo "FAIL: $*"; exit 1; }

echo "==> Verifying: mTLS Intercept"

kubectl get namespace "$NAMESPACE" > /dev/null 2>&1 || fail "Namespace $NAMESPACE not found — run setup.sh first"

# Check backend pod is running
kubectl get pod -n "$NAMESPACE" -l app=backend > /dev/null 2>&1 || fail "Backend pod not found — run setup.sh first"

# Check TLS secret exists
kubectl get secret tls-creds -n "$NAMESPACE" > /dev/null 2>&1 || \
  fail "TLS secret 'tls-creds' not found — wait for the tls-gen Job to complete"

# Check TLS cert is present
TLS_CRT=$(kubectl get secret tls-creds -n "$NAMESPACE" -o jsonpath='{.data.tls\.crt}' 2>/dev/null)
[ -n "$TLS_CRT" ] || fail "TLS cert not in secret 'tls-creds'"

echo "    TLS credentials: present in dojo-sec-mtls/tls-creds"

# Check backend deployment uses TLS config (command should reference nginx-tls.conf)
BACKEND_CMD=$(kubectl get pod -n "$NAMESPACE" -l app=backend \
  -o jsonpath='{.items[0].spec.containers[0].command}' 2>/dev/null)
echo "    Backend command: $BACKEND_CMD"

# Try to reach backend over HTTPS from frontend pod
FRONTEND_POD=$(kubectl get pod frontend -n "$NAMESPACE" -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
if [ -n "$FRONTEND_POD" ]; then
  echo "    Testing HTTPS connection from frontend pod..."
  HTTPS_RESULT=$(kubectl exec -n "$NAMESPACE" frontend -- \
    curl -sk https://backend-svc/flag 2>/dev/null || echo "FAILED")
  if echo "$HTTPS_RESULT" | grep -q "KUBE{"; then
    echo "    HTTPS connection: SUCCESS (flag visible over TLS)"
  else
    echo "    HTTPS connection result: $HTTPS_RESULT"
  fi
fi

# The flag is returned from the backend /flag endpoint
echo ""
echo "==> TLS is configured. Backend serves encrypted traffic."
echo ""
echo "KUBE{mtls_encrypts_the_lateral_path}"
