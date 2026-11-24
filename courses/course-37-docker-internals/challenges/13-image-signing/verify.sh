#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-docker-signing"

fail() {
  echo "FAIL: $1"
  exit 1
}

echo "==> Verifying: Image Signing"

# Check 1: annotation dojo.docker/signed = true
SIGNED=$(kubectl get deployment api -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.dojo\.docker/signed}' 2>/dev/null || echo "")
if [ "$SIGNED" != "true" ]; then
  fail "Deployment 'api' annotation dojo.docker/signed must be 'true' (got: '${SIGNED}'). After signing, run: kubectl annotate deployment api dojo.docker/signed=true -n $NAMESPACE"
fi
echo "    [OK] Deployment annotated as signed"

# Check 2: pod Running
RUNNING=$(kubectl get pods -n "$NAMESPACE" -l app=api \
  -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
if ! echo "$RUNNING" | grep -qw "Running"; then
  fail "No Running pod for Deployment 'api' in namespace $NAMESPACE."
fi
echo "    [OK] Pod is Running"

echo ""
echo "    Flag: KUBE{cosign_signs_oci_supply_chain}"
