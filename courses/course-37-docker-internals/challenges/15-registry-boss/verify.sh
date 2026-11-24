#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-docker-registry"

fail() {
  echo "FAIL: $1"
  exit 1
}

echo "==> Verifying: Registry Boss"

# Check 1: Deployment registry exists
kubectl get deployment registry -n "$NAMESPACE" >/dev/null 2>&1 || \
  fail "Deployment 'registry' not found in namespace $NAMESPACE. Create it."
echo "    [OK] Deployment 'registry' exists"

# Check 2: Registry pod Running
REG_RUNNING=$(kubectl get pods -n "$NAMESPACE" -l app=registry \
  -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
if ! echo "$REG_RUNNING" | grep -qw "Running"; then
  fail "No Running pod for registry Deployment. Check: kubectl get pods -n $NAMESPACE"
fi
echo "    [OK] Registry pod is Running"

# Check 3: Service registry-svc exists
kubectl get service registry-svc -n "$NAMESPACE" >/dev/null 2>&1 || \
  fail "Service 'registry-svc' not found in namespace $NAMESPACE. Create a ClusterIP service on port 5000."
echo "    [OK] Service 'registry-svc' exists"

# Check 4: Secret registry-auth exists
kubectl get secret registry-auth -n "$NAMESPACE" >/dev/null 2>&1 || \
  fail "Secret 'registry-auth' not found in namespace $NAMESPACE. Create it from your htpasswd file."
echo "    [OK] Secret 'registry-auth' exists"

# Check 5: Pod registry-consumer Running
CONSUMER=$(kubectl get pod registry-consumer -n "$NAMESPACE" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "$CONSUMER" != "Running" ]; then
  fail "Pod 'registry-consumer' is not Running (got: '${CONSUMER}'). Create it and ensure it can pull from your registry."
fi
echo "    [OK] Pod 'registry-consumer' is Running"

# Check 6: Annotation dojo.docker/registry-verified=true
VERIFIED=$(kubectl get deployment registry -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.dojo\.docker/registry-verified}' 2>/dev/null || echo "")
if [ "$VERIFIED" != "true" ]; then
  fail "Deployment 'registry' missing annotation dojo.docker/registry-verified=true. Run: kubectl annotate deployment registry dojo.docker/registry-verified=true -n $NAMESPACE"
fi
echo "    [OK] Deployment annotated as verified"

echo ""
echo "    Flag: KUBE{own_registry_serves_the_dojo}"
