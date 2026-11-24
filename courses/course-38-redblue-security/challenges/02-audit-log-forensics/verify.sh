#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-sec-forensics"
fail() { echo "FAIL: $*"; exit 1; }

echo "==> Verifying: Audit Log Forensics"

# Check namespace exists
kubectl get namespace "$NAMESPACE" > /dev/null 2>&1 || fail "Namespace $NAMESPACE not found — run setup.sh first"

# Check the audit trail ConfigMap exists
kubectl get configmap audit-trail -n "$NAMESPACE" > /dev/null 2>&1 || fail "audit-trail ConfigMap not found in $NAMESPACE"

# Check the target secret exists
kubectl get secret attacker-secret -n "$NAMESPACE" > /dev/null 2>&1 || fail "Secret 'attacker-secret' not found in $NAMESPACE"

# Read the flag field from the secret
FLAG_B64=$(kubectl get secret attacker-secret -n "$NAMESPACE" -o jsonpath='{.data.flag}' 2>/dev/null)
[ -n "$FLAG_B64" ] || fail "Secret 'attacker-secret' has no 'flag' data field"

FLAG=$(printf '%s' "$FLAG_B64" | base64 -d 2>/dev/null)
[ -n "$FLAG" ] || fail "Failed to decode the flag field"

echo ""
echo "==> Audit trail analysed. Secret identified. Flag retrieved."
echo ""
echo "$FLAG"
