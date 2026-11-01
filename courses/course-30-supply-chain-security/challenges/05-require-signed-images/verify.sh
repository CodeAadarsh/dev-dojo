#!/usr/bin/env bash
# Verifier for "Require Signed Images with Kyverno".
# Checks: ClusterPolicy 'require-signed-images' exists, is in Enforce mode,
# has a verifyImages rule, and is scoped to namespace 'dojo-supplychain'.
set -uo pipefail

FLAG='KUBE{admission_enforces_signed_images}'
POLICY="require-signed-images"
NS="dojo-supplychain"

fail() { echo "✗ $1"; exit 1; }

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Context is not 'kind-dojo' — verifying against current context."
fi

# Kyverno CRD must be present
kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1 \
  || fail "Kyverno is not installed — CRD clusterpolicies.kyverno.io not found"

# ClusterPolicy must exist
kubectl get clusterpolicy "$POLICY" >/dev/null 2>&1 \
  || fail "ClusterPolicy '$POLICY' not found — apply your policy first"

# Enforcement mode must be Enforce
ACTION=$(kubectl get clusterpolicy "$POLICY" \
  -o jsonpath='{.spec.validationFailureAction}' 2>/dev/null)
[ "$ACTION" = "Enforce" ] \
  || fail "validationFailureAction must be 'Enforce', got '${ACTION:-<empty>}'"

# At least one verifyImages rule must be present
kubectl get clusterpolicy "$POLICY" -o yaml | grep -q "verifyImages:" \
  || fail "no verifyImages rule found in ClusterPolicy '$POLICY' — add a verifyImages section to a rule"

# Policy must reference the target namespace
kubectl get clusterpolicy "$POLICY" -o yaml | grep -q "$NS" \
  || fail "ClusterPolicy does not reference namespace '$NS' — scope your rule's match.resources.namespaces"

echo
echo "All checks passed:"
echo "  ✓ ClusterPolicy '$POLICY' exists"
echo "  ✓ validationFailureAction: Enforce"
echo "  ✓ verifyImages rule present"
echo "  ✓ Namespace '$NS' referenced in the policy"
echo
echo "Submit this flag in the platform:"
echo
echo "    $FLAG"
