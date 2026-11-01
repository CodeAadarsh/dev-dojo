#!/usr/bin/env bash
# Verifier for "Canary Rollout".
# Checks: stable Deployment ready, canary Deployment ready, both pod templates
# share an 'app' label, a Service selects that shared label.
set -uo pipefail

NS="dojo-cicd"
FLAG='KUBE{canary_ships_with_traffic_split}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 \
  || fail "namespace '$NS' is missing — run setup.sh first"

# ── 1. Stable Deployment ─────────────────────────────────────────────────────
STABLE=$(kubectl -n "$NS" get deployments -l track=stable \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$STABLE" ] \
  || fail "no Deployment with label 'track=stable' found in $NS — run setup.sh to apply the stable Deployment"

STABLE_READY=$(kubectl -n "$NS" get deployment "$STABLE" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${STABLE_READY:-0}" -ge 1 ] \
  || fail "stable Deployment '$STABLE' has no ready replicas — check pod events: kubectl describe deploy $STABLE -n $NS"

# ── 2. Canary Deployment ──────────────────────────────────────────────────────
CANARY=$(kubectl -n "$NS" get deployments -l track=canary \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$CANARY" ] \
  || fail "no Deployment with label 'track=canary' found in $NS — complete canary.yaml and apply it: kubectl apply -f ~/.kube-dojo-work/05-canary-rollout/canary.yaml"

CANARY_READY=$(kubectl -n "$NS" get deployment "$CANARY" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${CANARY_READY:-0}" -ge 1 ] \
  || fail "canary Deployment '$CANARY' has no ready replicas — check: kubectl describe deploy $CANARY -n $NS"

# ── 3. Shared app label ───────────────────────────────────────────────────────
STABLE_APP=$(kubectl -n "$NS" get deployment "$STABLE" \
  -o jsonpath='{.spec.template.metadata.labels.app}' 2>/dev/null)
CANARY_APP=$(kubectl -n "$NS" get deployment "$CANARY" \
  -o jsonpath='{.spec.template.metadata.labels.app}' 2>/dev/null)

[ -n "$STABLE_APP" ] \
  || fail "stable Deployment pod template has no 'app' label — the Service needs a shared selector label"
[ -n "$CANARY_APP" ] \
  || fail "canary Deployment pod template has no 'app' label — add 'app: $STABLE_APP' to the pod template labels"
[ "$STABLE_APP" = "$CANARY_APP" ] \
  || fail "stable 'app' label ('$STABLE_APP') != canary 'app' label ('$CANARY_APP') — both must share the same 'app' label for the Service to route to both"

# ── 4. Service selects the shared label ──────────────────────────────────────
ALL_SVC_APPS=$(kubectl -n "$NS" get services \
  -o jsonpath='{range .items[*]}{.spec.selector.app}{" "}{end}' 2>/dev/null)
echo "$ALL_SVC_APPS" | grep -qw "$STABLE_APP" \
  || fail "no Service in $NS has 'spec.selector.app: $STABLE_APP' — ensure the Service selects the shared app label"

SVC=$(kubectl -n "$NS" get services \
  -o jsonpath="{range .items[*]}{.metadata.name}{\": \"}{.spec.selector.app}{\"\n\"}{end}" 2>/dev/null \
  | grep ": ${STABLE_APP}$" | head -1 | awk -F: '{print $1}' | tr -d ' ')

TOTAL=$((STABLE_READY + CANARY_READY))
CANARY_PCT=$((CANARY_READY * 100 / TOTAL))

echo "✓ stable Deployment               : $STABLE ($STABLE_READY ready)"
echo "✓ canary Deployment               : $CANARY ($CANARY_READY ready)"
echo "✓ shared app label                : $STABLE_APP"
echo "✓ Service routes to both          : $SVC"
echo "✓ approximate canary traffic      : ~${CANARY_PCT}% ($CANARY_READY/$TOTAL endpoints)"
echo
echo "Submit this flag:"
echo
echo "    $FLAG"
