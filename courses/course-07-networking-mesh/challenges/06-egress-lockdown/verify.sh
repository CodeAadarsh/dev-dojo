#!/usr/bin/env bash
# Verifier for "Egress Lockdown".
# Checks: at least one NetworkPolicy in dojo-egress has policyTypes including
# Egress, AND at least one NetworkPolicy has an egress rule allowing port 53.
# Prints flag on success.
set -uo pipefail

NS=dojo-egress
FLAG='KUBE{egress_lockdown_default_deny}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

NP_COUNT=$(kubectl -n "$NS" get networkpolicies -o name 2>/dev/null | wc -l | tr -d ' ')
[ "${NP_COUNT:-0}" -gt 0 ] \
  || fail "no NetworkPolicies found in $NS — author at least one before running the verifier"

# Check that at least one NP in the namespace has Egress in policyTypes
# We iterate over all NPs and check each one
HAS_EGRESS_POLICY=0
for NP in $(kubectl -n "$NS" get networkpolicies -o name 2>/dev/null); do
  NP_NAME="${NP#networkpolicy.networking.k8s.io/}"
  POLICY_TYPES=$(kubectl -n "$NS" get networkpolicy "$NP_NAME" \
    -o jsonpath='{.spec.policyTypes}' 2>/dev/null)
  case "$POLICY_TYPES" in
    *Egress*) HAS_EGRESS_POLICY=1; EGRESS_NP_NAME="$NP_NAME" ;;
  esac
done

[ "$HAS_EGRESS_POLICY" -eq 1 ] \
  || fail "no NetworkPolicy in $NS has policyTypes including 'Egress' — add at least one"

# Check that at least one NP has an egress rule with port 53
HAS_PORT_53=0
for NP in $(kubectl -n "$NS" get networkpolicies -o name 2>/dev/null); do
  NP_NAME="${NP#networkpolicy.networking.k8s.io/}"
  PORT0=$(kubectl -n "$NS" get networkpolicy "$NP_NAME" \
    -o jsonpath='{.spec.egress[0].ports[0].port}' 2>/dev/null)
  PORT1=$(kubectl -n "$NS" get networkpolicy "$NP_NAME" \
    -o jsonpath='{.spec.egress[0].ports[1].port}' 2>/dev/null)
  PORT2=$(kubectl -n "$NS" get networkpolicy "$NP_NAME" \
    -o jsonpath='{.spec.egress[1].ports[0].port}' 2>/dev/null)
  for P in "$PORT0" "$PORT1" "$PORT2"; do
    [ "$P" = "53" ] && HAS_PORT_53=1
  done
done

[ "$HAS_PORT_53" -eq 1 ] \
  || fail "no egress rule allowing port 53 found in any NetworkPolicy in $NS — DNS must be explicitly allowed"

echo "✓ NetworkPolicy with Egress policyType : $EGRESS_NP_NAME"
echo "✓ Egress rule allowing port 53         : found (DNS allowed)"
echo
echo "All egress lockdown checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
