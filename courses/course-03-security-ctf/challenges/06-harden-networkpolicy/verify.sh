#!/usr/bin/env bash
# Verifier for "Shut the Flat Network". Inspects the NetworkPolicy objects in
# dojo-hardnet and prints the flag only when a default-deny-ingress policy AND a
# scoped allow policy (role=frontend -> app=backend:80) both exist and are
# well-formed. kindnet does not enforce policy, so we assert on the objects, not
# on live connectivity. Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-hardnet
FLAG='KUBE{default_deny_then_allow_the_frontend}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get pod backend  >/dev/null 2>&1 || fail "pod 'backend' not found — run setup.sh first"
kubectl -n "$NS" get pod frontend >/dev/null 2>&1 || fail "pod 'frontend' not found — run setup.sh first"

NAMES=$(kubectl -n "$NS" get netpol -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
[ -n "$NAMES" ] || fail "no NetworkPolicy objects in '$NS' — you need a default-deny AND an allow policy"

# --- Check 1: a default-deny-ingress policy (empty selector, Ingress type, no rules)
DENY=""
for np in $NAMES; do
  ptypes=$(kubectl -n "$NS" get netpol "$np" -o jsonpath='{.spec.policyTypes[*]}' 2>/dev/null)
  case " $ptypes " in *" Ingress "*) ;; *) continue ;; esac
  sel=$(kubectl -n "$NS" get netpol "$np" -o jsonpath='{.spec.podSelector.matchLabels}' 2>/dev/null)
  selexpr=$(kubectl -n "$NS" get netpol "$np" -o jsonpath='{.spec.podSelector.matchExpressions}' 2>/dev/null)
  ing=$(kubectl -n "$NS" get netpol "$np" -o jsonpath='{.spec.ingress}' 2>/dev/null)
  if [ -z "$sel" ] && [ -z "$selexpr" ] && [ -z "$ing" ]; then
    DENY="$np"
    break
  fi
done
[ -n "$DENY" ] || fail "no default-deny-ingress policy found (need empty podSelector, policyTypes: [Ingress], and zero ingress rules)"

# --- Check 2: a scoped allow policy (selects app=backend, from role=frontend, port 80)
ALLOW=""
for np in $NAMES; do
  [ "$np" = "$DENY" ] && continue
  target=$(kubectl -n "$NS" get netpol "$np" -o jsonpath='{.spec.podSelector.matchLabels.app}' 2>/dev/null)
  [ "$target" = "backend" ] || continue
  fromrole=$(kubectl -n "$NS" get netpol "$np" -o jsonpath='{.spec.ingress[*].from[*].podSelector.matchLabels.role}' 2>/dev/null)
  case " $fromrole " in *" frontend "*) ;; *) continue ;; esac
  ports=$(kubectl -n "$NS" get netpol "$np" -o jsonpath='{.spec.ingress[*].ports[*].port}' 2>/dev/null)
  case " $ports " in *" 80 "*) ;; *) continue ;; esac
  ALLOW="$np"
  break
done
[ -n "$ALLOW" ] || fail "no matching allow policy found (need podSelector app=backend, ingress from podSelector role=frontend, port 80)"

echo "✓ default-deny-ingress policy : $DENY"
echo "✓ scoped allow policy         : $ALLOW (app=backend <- role=frontend :80)"
echo
echo "The namespace is default-deny with a single least-privilege allow. Submit this flag:"
echo
echo "    $FLAG"
