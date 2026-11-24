#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-sec-opa"
fail() { echo "FAIL: $*"; exit 1; }

echo "==> Verifying: OPA Policy Escape"

# Check namespace and constraint exist
kubectl get namespace "$NAMESPACE" > /dev/null 2>&1 || fail "Namespace $NAMESPACE not found — run setup.sh first"
kubectl get blockprivilegedcontainer block-privileged-containers > /dev/null 2>&1 || fail "Constraint not found — run setup.sh first"

# Check the constraint now matches Pods
KINDS=$(kubectl get blockprivilegedcontainer block-privileged-containers \
  -o jsonpath='{.spec.match.kinds[*].kinds}' 2>/dev/null)
echo "    Constraint kinds: $KINDS"

# Try to create a privileged bare Pod — it MUST be rejected
echo "    Testing: attempting to create privileged Pod (must be rejected)..."
TEST_RESULT=$(kubectl apply -f - 2>&1 <<'PODEOF'
apiVersion: v1
kind: Pod
metadata:
  name: priv-test-pod
  namespace: dojo-sec-opa
spec:
  containers:
  - name: test
    image: busybox
    securityContext:
      privileged: true
    command: [sleep, "1"]
PODEOF
)
echo "    Result: $TEST_RESULT"

# Clean up if it somehow got created
kubectl delete pod priv-test-pod -n "$NAMESPACE" --ignore-not-found=true > /dev/null 2>&1

# Check if it was rejected
if echo "$TEST_RESULT" | grep -qiE "(denied|forbidden|violat|must not run as privileged)"; then
  echo "    Policy correctly rejected the privileged Pod."
else
  fail "Privileged Pod was NOT rejected. Fix the constraint: add kind 'Pod' with apiGroup '' to spec.match.kinds"
fi

# Read the reward
FLAG_B64=$(kubectl get secret opa-reward -n "$NAMESPACE" -o jsonpath='{.data.flag}' 2>/dev/null)
[ -n "$FLAG_B64" ] || fail "Reward secret not found — run setup.sh first"
FLAG=$(printf '%s' "$FLAG_B64" | base64 -d)

echo ""
echo "==> OPA constraint now correctly blocks privileged Pods."
echo ""
echo "$FLAG"
