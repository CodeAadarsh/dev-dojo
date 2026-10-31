#!/usr/bin/env bash
# Verifier for "NetworkPolicy Lockdown". Confirms the POLICY OBJECTS exist:
#   (1) a default-deny-ingress policy  — policyTypes:[Ingress], empty podSelector,
#       and NO ingress rules;
#   (2) an allow policy selecting app=backend that admits ingress from a
#       podSelector role=frontend on port 80.
# kind's kindnet does not enforce NetworkPolicy, so we inspect the objects, not
# live packet drops. Prints the flag only when both exist. Exit 0 = solved, 1 = not yet.
# Uses only kubectl + POSIX tools (no jq).
set -uo pipefail

NS=dojo-netpol
FLAG='KUBE{default_deny_then_allow_only_frontend}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get deploy backend >/dev/null 2>&1 || fail "Deployment 'backend' not found in $NS — run setup.sh first"

NPS=$(kubectl -n "$NS" get networkpolicy -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
[ -n "$NPS" ] || fail "no NetworkPolicy exists in $NS — you need a default-deny AND a frontend allow policy"

DENY=""
ALLOW=""
for np in $NPS; do
  PT=$(kubectl -n "$NS" get networkpolicy "$np" -o jsonpath='{.spec.policyTypes[*]}' 2>/dev/null)
  ING=$(kubectl -n "$NS" get networkpolicy "$np" -o jsonpath='{.spec.ingress}' 2>/dev/null)
  SEL_LABELS=$(kubectl -n "$NS" get networkpolicy "$np" -o jsonpath='{.spec.podSelector.matchLabels}' 2>/dev/null)
  SEL_EXPR=$(kubectl -n "$NS" get networkpolicy "$np" -o jsonpath='{.spec.podSelector.matchExpressions}' 2>/dev/null)

  # (1) default-deny-ingress: targets Ingress, selects ALL pods (empty
  #     podSelector), and defines NO ingress rules — so everything is denied.
  if printf ' %s ' "$PT" | grep -q ' Ingress ' && [ -z "$ING" ] && [ -z "$SEL_LABELS" ] && [ -z "$SEL_EXPR" ]; then
    DENY="$np"
    continue
  fi

  # (2) allow policy: selects app=backend; admits from podSelector role=frontend on port 80.
  APP=$(kubectl -n "$NS" get networkpolicy "$np" -o jsonpath='{.spec.podSelector.matchLabels.app}' 2>/dev/null)
  ROLE=$(kubectl -n "$NS" get networkpolicy "$np" -o jsonpath='{.spec.ingress[*].from[*].podSelector.matchLabels.role}' 2>/dev/null)
  PORTS=$(kubectl -n "$NS" get networkpolicy "$np" -o jsonpath='{.spec.ingress[*].ports[*].port}' 2>/dev/null)
  if [ "$APP" = "backend" ] && printf ' %s ' "$ROLE" | grep -q ' frontend ' && printf ' %s ' "$PORTS" | grep -q ' 80 '; then
    ALLOW="$np"
  fi
done

[ -n "$DENY" ] || fail "no default-deny-ingress found — need policyTypes:[Ingress], empty podSelector ({}), and NO ingress rules"
[ -n "$ALLOW" ] || fail "no frontend allow found — need podSelector app=backend, ingress from podSelector role=frontend, on port 80"

echo "✓ namespace                 : $NS"
echo "✓ default-deny-ingress      : $DENY  (selects all pods, no ingress rules)"
echo "✓ allow policy              : $ALLOW (selects app=backend)"
echo "✓ allowed source            : podSelector role=frontend"
echo "✓ allowed port              : 80"
echo
echo "Deny-by-default is in place, with exactly one audited frontend->backend allow."
echo "Submit this flag in the platform:"
echo
echo "    $FLAG"
