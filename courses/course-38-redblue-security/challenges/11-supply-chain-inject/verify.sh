#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-sec-supplychain"
FLAG="KUBE{sbom_diff_reveals_injected_package}"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Check 1: sbom-diff-result ConfigMap exists with correct malicious_package
MALICIOUS=$(kubectl get configmap sbom-diff-result -n "$NAMESPACE" \
  -o jsonpath='{.data.malicious_package}' 2>/dev/null) || \
  fail "ConfigMap 'sbom-diff-result' not found in $NAMESPACE. Run: kubectl create configmap sbom-diff-result -n $NAMESPACE --from-literal=malicious_package=<package>"

[ "$MALICIOUS" = "lodash-dev-proxy" ] || \
  fail "malicious_package is '$MALICIOUS', expected 'lodash-dev-proxy'. Regenerate the SBOM diff."

# Check 2: Deployment is using the clean image (not 1.1)
CURRENT_IMAGE=$(kubectl get deployment app -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null) || \
  fail "Deployment 'app' not found in $NAMESPACE"

case "$CURRENT_IMAGE" in
  *"1.1"*) fail "Deployment still uses infected image '$CURRENT_IMAGE'. Run: kubectl set image deployment/app web=dojo/app-clean:1.0 -n $NAMESPACE" ;;
  *"clean"*|*"1.0"*) ;;
  *) fail "Unexpected image '$CURRENT_IMAGE' — expected dojo/app-clean:1.0" ;;
esac

# Check 3: Namespace annotated as remediated
STATUS=$(kubectl get namespace "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.dojo\.supply-chain/status}' 2>/dev/null) || \
  fail "Namespace $NAMESPACE not found"

[ "$STATUS" = "remediated" ] || \
  fail "Namespace annotation dojo.supply-chain/status is '$STATUS', expected 'remediated'. Run: kubectl annotate namespace $NAMESPACE dojo.supply-chain/status=remediated --overwrite"

echo ""
echo "All checks passed."
echo ""
echo "FLAG: $FLAG"
