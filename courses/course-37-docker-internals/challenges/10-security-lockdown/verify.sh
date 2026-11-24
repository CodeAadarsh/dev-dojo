#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-docker-security"

fail() {
  echo "FAIL: $1"
  exit 1
}

echo "==> Verifying: Security Lockdown"

# Check 1: runAsNonRoot
RUN_AS_NON_ROOT=$(kubectl get deployment app -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.securityContext.runAsNonRoot}' 2>/dev/null || echo "")
if [ "$RUN_AS_NON_ROOT" != "true" ]; then
  fail "spec.template.spec.securityContext.runAsNonRoot must be 'true' (got: '${RUN_AS_NON_ROOT}'). Add a pod-level securityContext."
fi
echo "    [OK] runAsNonRoot: true"

# Check 2: allowPrivilegeEscalation
APE=$(kubectl get deployment app -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation}' 2>/dev/null || echo "")
if [ "$APE" != "false" ]; then
  fail "containers[0].securityContext.allowPrivilegeEscalation must be 'false' (got: '${APE}'). Add it to the container securityContext."
fi
echo "    [OK] allowPrivilegeEscalation: false"

# Check 3: readOnlyRootFilesystem
RORF=$(kubectl get deployment app -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem}' 2>/dev/null || echo "")
if [ "$RORF" != "true" ]; then
  fail "containers[0].securityContext.readOnlyRootFilesystem must be 'true' (got: '${RORF}'). Don't forget to add emptyDir volumes for /var/cache/nginx and /var/run."
fi
echo "    [OK] readOnlyRootFilesystem: true"

# Check 4: capabilities.drop contains ALL
CAP_DROP=$(kubectl get deployment app -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].securityContext.capabilities.drop[0]}' 2>/dev/null || echo "")
if [ "$CAP_DROP" != "ALL" ]; then
  fail "containers[0].securityContext.capabilities.drop[0] must be 'ALL' (got: '${CAP_DROP}'). Set capabilities: {drop: [\"ALL\"]}."
fi
echo "    [OK] capabilities.drop: [ALL]"

# Check 5: pod Running
RUNNING=$(kubectl get pods -n "$NAMESPACE" -l app=app \
  -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
if ! echo "$RUNNING" | grep -qw "Running"; then
  fail "No Running pod found. Check 'kubectl get pods -n $NAMESPACE' — nginx may be crashing because it needs writable emptyDir mounts."
fi
echo "    [OK] Pod is Running"

echo ""
echo "    Flag: KUBE{drop_all_caps_read_only_safe}"
