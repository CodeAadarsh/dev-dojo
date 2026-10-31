#!/usr/bin/env bash
# Verifier for "Default Deny Then Allow".
# Checks that both NetworkPolicy objects are authored correctly.
set -uo pipefail

NS=dojo-np
FLAG='KUBE{default_deny_then_allow_is_zero_trust}'

fail() { echo "x $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

# Check default-deny-ingress NetworkPolicy exists
kubectl -n "$NS" get networkpolicy default-deny-ingress >/dev/null 2>&1 \
  || fail "NetworkPolicy 'default-deny-ingress' not found in $NS"

# Check it has an empty podSelector (matches all pods)
DENY_SELECTOR=$(kubectl -n "$NS" get networkpolicy default-deny-ingress \
  -o jsonpath='{.spec.podSelector}' 2>/dev/null)
# An empty podSelector serialises as '{}' or 'map[]' — check it has no matchLabels key with values
DENY_ML=$(kubectl -n "$NS" get networkpolicy default-deny-ingress \
  -o jsonpath='{.spec.podSelector.matchLabels}' 2>/dev/null)
[ -z "$DENY_ML" ] \
  || fail "NetworkPolicy 'default-deny-ingress' podSelector must be empty {} (found matchLabels: $DENY_ML)"

# Check policyTypes includes Ingress
POLICY_TYPES=$(kubectl -n "$NS" get networkpolicy default-deny-ingress \
  -o jsonpath='{.spec.policyTypes}' 2>/dev/null)
echo "$POLICY_TYPES" | grep -q "Ingress" \
  || fail "NetworkPolicy 'default-deny-ingress' policyTypes must include 'Ingress' (found: $POLICY_TYPES)"

# Check allow-frontend-to-backend NetworkPolicy exists
kubectl -n "$NS" get networkpolicy allow-frontend-to-backend >/dev/null 2>&1 \
  || fail "NetworkPolicy 'allow-frontend-to-backend' not found in $NS"

# Check the allow policy targets role=backend
ALLOW_TARGET=$(kubectl -n "$NS" get networkpolicy allow-frontend-to-backend \
  -o jsonpath='{.spec.podSelector.matchLabels.role}' 2>/dev/null)
[ "$ALLOW_TARGET" = "backend" ] \
  || fail "NetworkPolicy 'allow-frontend-to-backend' spec.podSelector.matchLabels.role must be 'backend' (found: '${ALLOW_TARGET:-unset}')"

# Check the ingress rule has a from.podSelector matching role=frontend
INGRESS_FROM=$(kubectl -n "$NS" get networkpolicy allow-frontend-to-backend \
  -o jsonpath='{.spec.ingress[0].from[0].podSelector.matchLabels.role}' 2>/dev/null)
[ "$INGRESS_FROM" = "frontend" ] \
  || fail "Allow policy ingress.from[0].podSelector.matchLabels.role must be 'frontend' (found: '${INGRESS_FROM:-unset}')"

# Check the ingress rule allows port 80
INGRESS_PORT=$(kubectl -n "$NS" get networkpolicy allow-frontend-to-backend \
  -o jsonpath='{.spec.ingress[0].ports[0].port}' 2>/dev/null)
[ "$INGRESS_PORT" = "80" ] \
  || fail "Allow policy ingress.ports[0].port must be 80 (found: '${INGRESS_PORT:-unset}')"

echo "v default-deny-ingress NetworkPolicy : podSelector={}, policyTypes=[Ingress]"
echo "v allow-frontend-to-backend          : targets role=backend, allows role=frontend on port 80"
echo
echo "All NetworkPolicy checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
