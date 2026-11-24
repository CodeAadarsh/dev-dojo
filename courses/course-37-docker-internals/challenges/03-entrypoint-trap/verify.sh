#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-docker-entrypoint"
FLAG="KUBE{entrypoint_runs_cmd_as_args}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

echo "==> Verifying 03-entrypoint-trap..."

# Check deployment exists
kubectl get deployment web -n "$NAMESPACE" > /dev/null 2>&1 \
  || fail "Deployment 'web' not found in namespace $NAMESPACE"

# Get pod name
POD=$(kubectl get pod -n "$NAMESPACE" -l app=web \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$POD" ] || fail "No pods found for Deployment 'web' in $NAMESPACE"

# Check pod phase
PHASE=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
[ "$PHASE" = "Running" ] || fail "Pod $POD is in phase '$PHASE', not Running"

# Check container state is running (not just pod phase)
STATE=$(kubectl get pod "$POD" -n "$NAMESPACE" \
  -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}')
[ -n "$STATE" ] || fail "Container is not in running state (it may still be restarting)"

echo "✓ Deployment web exists"
echo "✓ Pod $POD is Running"
echo ""
echo "Flag: $FLAG"
