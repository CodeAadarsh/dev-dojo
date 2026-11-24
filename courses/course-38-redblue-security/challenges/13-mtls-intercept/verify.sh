#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-sec-mtls"
FLAG="KUBE{mtls_encrypts_the_lateral_path}"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Check 1: frontend deployment annotated as mtls-enforced
FE_STATUS=$(kubectl get deployment frontend -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.dojo\.mtls/status}' 2>/dev/null) || \
  fail "Deployment 'frontend' not found in $NAMESPACE"

[ "$FE_STATUS" = "mtls-enforced" ] || \
  fail "frontend annotation dojo.mtls/status is '$FE_STATUS', expected 'mtls-enforced'. Run: kubectl annotate deployment frontend dojo.mtls/status=mtls-enforced -n $NAMESPACE --overwrite"

# Check 2: backend deployment annotated as mtls-enforced
BE_STATUS=$(kubectl get deployment backend -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.dojo\.mtls/status}' 2>/dev/null) || \
  fail "Deployment 'backend' not found in $NAMESPACE"

[ "$BE_STATUS" = "mtls-enforced" ] || \
  fail "backend annotation dojo.mtls/status is '$BE_STATUS', expected 'mtls-enforced'. Run: kubectl annotate deployment backend dojo.mtls/status=mtls-enforced -n $NAMESPACE --overwrite"

# Check 3: mtls-config ConfigMap exists
kubectl get configmap mtls-config -n "$NAMESPACE" >/dev/null 2>&1 || \
  fail "ConfigMap 'mtls-config' not found in $NAMESPACE. Create it to document your mTLS setup method."

echo ""
echo "mTLS enforced on both services."
echo ""
echo "FLAG: $FLAG"
