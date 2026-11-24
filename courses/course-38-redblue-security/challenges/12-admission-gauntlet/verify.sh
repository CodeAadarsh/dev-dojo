#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-sec-gauntlet"
FLAG="KUBE{five_policies_block_five_attacks}"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Check policy-evidence ConfigMap exists with all 5 keys = "blocked"
kubectl get configmap policy-evidence -n "$NAMESPACE" >/dev/null 2>&1 || \
  fail "ConfigMap 'policy-evidence' not found in $NAMESPACE. Create it with all 5 keys set to 'blocked'."

PRIV=$(kubectl get configmap policy-evidence -n "$NAMESPACE" -o jsonpath='{.data.privileged}' 2>/dev/null)
HP=$(kubectl get configmap policy-evidence -n "$NAMESPACE" -o jsonpath='{.data.hostpath}' 2>/dev/null)
ROOT=$(kubectl get configmap policy-evidence -n "$NAMESPACE" -o jsonpath='{.data.root-user}' 2>/dev/null)
LIMITS=$(kubectl get configmap policy-evidence -n "$NAMESPACE" -o jsonpath='{.data.no-limits}' 2>/dev/null)
LATEST=$(kubectl get configmap policy-evidence -n "$NAMESPACE" -o jsonpath='{.data.latest-tag}' 2>/dev/null)

[ "$PRIV" = "blocked" ]   || fail "policy-evidence.privileged is '$PRIV', expected 'blocked'"
[ "$HP" = "blocked" ]     || fail "policy-evidence.hostpath is '$HP', expected 'blocked'"
[ "$ROOT" = "blocked" ]   || fail "policy-evidence.root-user is '$ROOT', expected 'blocked'"
[ "$LIMITS" = "blocked" ] || fail "policy-evidence.no-limits is '$LIMITS', expected 'blocked'"
[ "$LATEST" = "blocked" ] || fail "policy-evidence.latest-tag is '$LATEST', expected 'blocked'"

echo ""
echo "All 5 attack patterns blocked."
echo ""
echo "FLAG: $FLAG"
