#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-docker-network"
FLAG="KUBE{iptables_rules_docker_network}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

echo "==> Verifying 08-network-detective..."

# Check service selector is correct
SELECTOR=$(kubectl get service backend-svc -n "$NAMESPACE" \
  -o jsonpath='{.spec.selector.app}' 2>/dev/null || true)
[ "$SELECTOR" = "backend" ] \
  || fail "Service backend-svc selector is '$SELECTOR', expected 'backend' — patch the service selector"

# Check endpoints are populated
ENDPOINT_IP=$(kubectl get endpoints backend-svc -n "$NAMESPACE" \
  -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
[ -n "$ENDPOINT_IP" ] \
  || fail "Service backend-svc has no endpoints — selector may still be wrong or backend pods not Ready"

# Check frontend pod is Running
FRONT_POD=$(kubectl get pod -n "$NAMESPACE" -l app=frontend \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$FRONT_POD" ] || fail "No frontend pods found"

PHASE=$(kubectl get pod "$FRONT_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
[ "$PHASE" = "Running" ] || fail "Frontend pod is in phase '$PHASE', not Running"

echo "✓ Service selector: app=backend (correct)"
echo "✓ Endpoints populated: $ENDPOINT_IP"
echo "✓ Frontend pod Running"
echo ""
echo "Flag: $FLAG"
