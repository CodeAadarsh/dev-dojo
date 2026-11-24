#!/usr/bin/env bash
set -uo pipefail

NS_BOSS="dojo-sec-boss"
NS_VAULT="dojo-sec-boss-vault"
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "    [PASS] $*"; }

echo "==> Verifying: Red Team Lab Boss"
echo ""
echo "--- ATTACK PHASE VERIFICATION ---"

# Check namespace
kubectl get namespace "$NS_BOSS" > /dev/null 2>&1 || fail "Namespace $NS_BOSS not found — run setup.sh first"
kubectl get namespace "$NS_VAULT" > /dev/null 2>&1 || fail "Namespace $NS_VAULT not found — run setup.sh first"

# Check attack-progress ConfigMap exists
kubectl get configmap attack-progress -n "$NS_BOSS" > /dev/null 2>&1 || \
  fail "attack-progress ConfigMap not found in $NS_BOSS.
  Complete the attack phase first:
  1. kubectl exec -n $NS_BOSS \$(kubectl get pod -n $NS_BOSS -l app=exposed-app -o jsonpath='{.items[0].metadata.name}') -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
  2. Use the token to read the crown-jewels secret in $NS_VAULT
  3. kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: attack-progress
  namespace: $NS_BOSS
data:
  step1: read-sa-token
  step2: found-cluster-admin
  step3: read-crown-jewels
EOF"

# Verify attack steps are recorded
S1=$(kubectl get configmap attack-progress -n "$NS_BOSS" -o jsonpath='{.data.step1}' 2>/dev/null)
S2=$(kubectl get configmap attack-progress -n "$NS_BOSS" -o jsonpath='{.data.step2}' 2>/dev/null)
S3=$(kubectl get configmap attack-progress -n "$NS_BOSS" -o jsonpath='{.data.step3}' 2>/dev/null)

[ -n "$S1" ] || fail "attack-progress missing step1"
[ -n "$S2" ] || fail "attack-progress missing step2"
[ -n "$S3" ] || fail "attack-progress missing step3"

pass "Attack step 1: $S1"
pass "Attack step 2: $S2"
pass "Attack step 3: $S3"

echo ""
echo "--- HARDENING PHASE VERIFICATION ---"

# Hardening check 1: dangerous-crb must be GONE
CRB_EXISTS=$(kubectl get clusterrolebinding dangerous-crb 2>/dev/null | wc -l)
if [ "$CRB_EXISTS" -eq 0 ]; then
  pass "dangerous-crb ClusterRoleBinding deleted"
else
  fail "HARDENING: dangerous-crb still exists. Run: kubectl delete clusterrolebinding dangerous-crb"
fi

# Hardening check 2: default SA must have automountServiceAccountToken: false
AUTO_MOUNT=$(kubectl get serviceaccount default -n "$NS_BOSS" \
  -o jsonpath='{.automountServiceAccountToken}' 2>/dev/null)
if [ "$AUTO_MOUNT" = "false" ]; then
  pass "default SA has automountServiceAccountToken: false"
else
  fail "HARDENING: default SA still auto-mounts tokens. Run: kubectl patch serviceaccount default -n $NS_BOSS -p '{\"automountServiceAccountToken\": false}'"
fi

# Hardening check 3: NetworkPolicy must exist in NS_BOSS
NP_COUNT=$(kubectl get networkpolicy -n "$NS_BOSS" 2>/dev/null | grep -v "^NAME" | wc -l)
if [ "$NP_COUNT" -gt 0 ]; then
  pass "NetworkPolicy exists in $NS_BOSS ($NP_COUNT policy/policies)"
else
  fail "HARDENING: No NetworkPolicy in $NS_BOSS. Apply a default-deny NetworkPolicy."
fi

# Hardening check 4: crown-jewels must still exist (rotated)
kubectl get secret crown-jewels -n "$NS_VAULT" > /dev/null 2>&1 || \
  fail "HARDENING: crown-jewels secret in $NS_VAULT was deleted but not recreated. Recreate it: kubectl create secret generic crown-jewels -n $NS_VAULT --from-literal=secret=new-value"

# Verify crown-jewels was rotated (different from original)
ORIGINAL_SECRET_VAL="crown-jewels-value-attack-found-this"
CURRENT_B64=$(kubectl get secret crown-jewels -n "$NS_VAULT" -o jsonpath='{.data.secret}' 2>/dev/null)
CURRENT=$(printf '%s' "$CURRENT_B64" | base64 -d 2>/dev/null || echo "")
if [ "$CURRENT" = "$ORIGINAL_SECRET_VAL" ]; then
  fail "HARDENING: crown-jewels secret value was NOT rotated (still the original). Delete and recreate with a new value."
fi
pass "crown-jewels secret rotated (new value present)"

# Read the flag
FLAG_B64=$(kubectl get configmap boss-reward -n "$NS_BOSS" -o jsonpath='{.data.flag_b64}' 2>/dev/null)
[ -n "$FLAG_B64" ] || fail "boss-reward ConfigMap not found — run setup.sh first"
FLAG=$(printf '%s' "$FLAG_B64" | base64 -d)

echo ""
echo "==> ATTACK PHASE: completed (3/3 steps)"
echo "==> HARDENING PHASE: completed (4/4 controls)"
echo ""
echo "Full kill chain owned. Full defense stack applied."
echo ""
echo "$FLAG"
