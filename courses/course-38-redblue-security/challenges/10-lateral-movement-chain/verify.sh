#!/usr/bin/env bash
set -uo pipefail

NS3="dojo-sec-lateral-hop3"
fail() { echo "FAIL: $*"; exit 1; }

echo "==> Verifying: Lateral Movement Chain"

# Check the final treasure secret exists in hop3 namespace
kubectl get namespace "$NS3" > /dev/null 2>&1 || fail "Namespace $NS3 not found — run setup.sh first"
kubectl get secret final-treasure -n "$NS3" > /dev/null 2>&1 || fail "Secret final-treasure not found in $NS3 — run setup.sh first"

# Read the flag
FLAG_B64=$(kubectl get secret final-treasure -n "$NS3" -o jsonpath='{.data.flag}' 2>/dev/null)
[ -n "$FLAG_B64" ] || fail "Secret final-treasure has no 'flag' data field"

FLAG=$(printf '%s' "$FLAG_B64" | base64 -d 2>/dev/null)
[ -n "$FLAG" ] || fail "Failed to decode flag"

echo "    Namespaces: dojo-sec-lateral → dojo-sec-lateral-hop2 → dojo-sec-lateral-hop3"
echo "    final-treasure secret found in $NS3"
echo ""
echo "==> Three-hop lateral movement chain completed."
echo ""
echo "$FLAG"
