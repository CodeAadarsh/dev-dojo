#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-docker-distroless"

fail() {
  echo "FAIL: $1"
  exit 1
}

echo "==> Verifying: Distroless Debug"

# Check 1: DATABASE_URL no longer contains wrong-host
DB_URL=$(kubectl get configmap app-config -n "$NAMESPACE" \
  -o jsonpath='{.data.DATABASE_URL}' 2>/dev/null || echo "")
if [ -z "$DB_URL" ]; then
  fail "ConfigMap 'app-config' not found or DATABASE_URL key is missing."
fi
if echo "$DB_URL" | grep -q "wrong-host"; then
  fail "ConfigMap 'app-config' still has 'wrong-host' in DATABASE_URL: '${DB_URL}'. Fix the value and rollout restart."
fi
echo "    [OK] DATABASE_URL no longer points to wrong-host"

# Check 2: Pod Running
RUNNING=$(kubectl get pods -n "$NAMESPACE" -l app=api \
  -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
if ! echo "$RUNNING" | grep -qw "Running"; then
  fail "No Running pod for Deployment 'api'. After fixing the ConfigMap, run: kubectl rollout restart deployment api -n $NAMESPACE"
fi
echo "    [OK] Pod is Running"

echo ""
echo "    Flag: KUBE{ephemeral_debug_distroless_pod}"
