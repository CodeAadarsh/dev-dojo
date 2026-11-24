#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-sec-incident"
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "    [PASS] $*"; }

echo "==> Verifying: Incident Playbook"

kubectl get namespace "$NAMESPACE" > /dev/null 2>&1 || fail "Namespace $NAMESPACE not found — run setup.sh first"

# Step 1: IDENTIFY — pod must have label dojo.incident/identified=true
echo "    Checking IDENTIFY step..."
IDENTIFIED=$(kubectl get pod malicious-pod -n "$NAMESPACE" \
  -o jsonpath='{.metadata.labels.dojo\.incident/identified}' 2>/dev/null || echo "")
if [ "$IDENTIFIED" = "true" ]; then
  pass "IDENTIFY: malicious-pod labeled dojo.incident/identified=true"
else
  fail "IDENTIFY not done: kubectl label pod malicious-pod -n $NAMESPACE dojo.incident/identified=true"
fi

# Step 2: CONTAIN — pod must have label dojo.incident/contained=true
echo "    Checking CONTAIN step..."
CONTAINED=$(kubectl get pod malicious-pod -n "$NAMESPACE" \
  -o jsonpath='{.metadata.labels.dojo\.incident/contained}' 2>/dev/null || echo "")
if [ "$CONTAINED" = "true" ]; then
  pass "CONTAIN: malicious-pod labeled dojo.incident/contained=true"
else
  fail "CONTAIN not done: kubectl label pod malicious-pod -n $NAMESPACE dojo.incident/contained=true"
fi

# Step 3: ERADICATE — suspicious-crb must NOT exist
echo "    Checking ERADICATE step..."
CRB_EXISTS=$(kubectl get clusterrolebinding suspicious-crb 2>/dev/null | wc -l)
if [ "$CRB_EXISTS" -eq 0 ]; then
  pass "ERADICATE: suspicious-crb ClusterRoleBinding deleted"
else
  fail "ERADICATE not done: kubectl delete clusterrolebinding suspicious-crb"
fi

# Step 4: RECOVER — leaked-creds must be GONE, rotated-creds must EXIST
echo "    Checking RECOVER step..."
LEAKED_EXISTS=$(kubectl get secret leaked-creds -n "$NAMESPACE" 2>/dev/null | wc -l)
if [ "$LEAKED_EXISTS" -gt 0 ]; then
  fail "RECOVER not done: leaked-creds secret still exists — delete it: kubectl delete secret leaked-creds -n $NAMESPACE"
fi

ROTATED_EXISTS=$(kubectl get secret rotated-creds -n "$NAMESPACE" 2>/dev/null | wc -l)
if [ "$ROTATED_EXISTS" -eq 0 ]; then
  fail "RECOVER not complete: rotated-creds secret doesn't exist — create it: kubectl create secret generic rotated-creds --from-literal=password=new-pass -n $NAMESPACE"
fi
pass "RECOVER: leaked-creds deleted, rotated-creds created"

# Read flag
FLAG_B64=$(kubectl get configmap incident-reward -n "$NAMESPACE" -o jsonpath='{.data.flag_b64}' 2>/dev/null)
[ -n "$FLAG_B64" ] || fail "incident-reward ConfigMap not found — run setup.sh first"
FLAG=$(printf '%s' "$FLAG_B64" | base64 -d)

echo ""
echo "==> All PICERL steps completed in order."
echo ""
echo "$FLAG"
