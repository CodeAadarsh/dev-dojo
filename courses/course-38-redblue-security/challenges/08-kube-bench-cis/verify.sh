#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-sec-cis"
fail() { echo "FAIL: $*"; exit 1; }

echo "==> Verifying: kube-bench CIS Hardening"

# Check namespace
kubectl get namespace "$NAMESPACE" > /dev/null 2>&1 || fail "Namespace $NAMESPACE not found — run setup.sh first"

# Check kube-bench results ConfigMap exists
kubectl get configmap kube-bench-results -n "$NAMESPACE" > /dev/null 2>&1 || \
  fail "kube-bench-results ConfigMap not found — run setup.sh first"

echo "    Checking CIS results..."

# Read the output
OUTPUT=$(kubectl get configmap kube-bench-results -n "$NAMESPACE" -o jsonpath='{.data.output}' 2>/dev/null)
[ -n "$OUTPUT" ] || fail "kube-bench-results ConfigMap has no 'output' key"

# Check the 5 required PASS checks are present
check_pass() {
  local id="$1"
  local desc="$2"
  if echo "$OUTPUT" | grep -q "^\[PASS\] $id"; then
    echo "    [PASS] $id — $desc"
  else
    fail "Check $id not passing in kube-bench results — '$desc' must PASS"
  fi
}

check_pass "1.2.1" "API server anonymous-auth=false"
check_pass "1.2.7" "API server authorization-mode includes RBAC"
check_pass "1.2.16" "API server insecure-port=0"
check_pass "4.2.1" "Kubelet anonymous-auth=false"
check_pass "4.2.2" "Kubelet authorization-mode not AlwaysAllow"

# Read the flag
FLAG_B64=$(kubectl get secret cis-reward -n "$NAMESPACE" -o jsonpath='{.data.flag}' 2>/dev/null)
[ -n "$FLAG_B64" ] || fail "Reward secret not found — run setup.sh first"
FLAG=$(printf '%s' "$FLAG_B64" | base64 -d)

echo ""
echo "==> 5 CIS Level 1 checks confirmed PASS."
echo "    kube-bench output understood. Cluster hardening baseline verified."
echo ""
echo "$FLAG"
