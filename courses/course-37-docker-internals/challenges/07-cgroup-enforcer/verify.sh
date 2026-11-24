#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-docker-cgroup"
FLAG="KUBE{cgroup_throttles_at_the_kernel}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

echo "==> Verifying 07-cgroup-enforcer..."

kubectl get deployment hog -n "$NAMESPACE" > /dev/null 2>&1 \
  || fail "Deployment 'hog' not found in namespace $NAMESPACE"

POD=$(kubectl get pod -n "$NAMESPACE" -l app=hog \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$POD" ] || fail "No pods found for label app=hog in $NAMESPACE"

PHASE=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
[ "$PHASE" = "Running" ] || fail "Pod $POD is in phase '$PHASE', not Running"

# Check limits
CPU_LIMIT=$(kubectl get pod "$POD" -n "$NAMESPACE" \
  -o jsonpath='{.spec.containers[0].resources.limits.cpu}' 2>/dev/null || true)
MEM_LIMIT=$(kubectl get pod "$POD" -n "$NAMESPACE" \
  -o jsonpath='{.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)

[ -n "$CPU_LIMIT" ]  || fail "No CPU limit set on pod — add resources.limits.cpu to the Deployment"
[ -n "$MEM_LIMIT" ]  || fail "No memory limit set on pod — add resources.limits.memory to the Deployment"

# Check requests
CPU_REQ=$(kubectl get pod "$POD" -n "$NAMESPACE" \
  -o jsonpath='{.spec.containers[0].resources.requests.cpu}' 2>/dev/null || true)
MEM_REQ=$(kubectl get pod "$POD" -n "$NAMESPACE" \
  -o jsonpath='{.spec.containers[0].resources.requests.memory}' 2>/dev/null || true)

[ -n "$CPU_REQ" ] || fail "No CPU request set — add resources.requests.cpu to the Deployment"
[ -n "$MEM_REQ" ] || fail "No memory request set — add resources.requests.memory to the Deployment"

echo "✓ Pod $POD is Running"
echo "✓ CPU limit:    $CPU_LIMIT"
echo "✓ Memory limit: $MEM_LIMIT"
echo "✓ CPU request:    $CPU_REQ"
echo "✓ Memory request: $MEM_REQ"
echo ""
echo "Flag: $FLAG"
