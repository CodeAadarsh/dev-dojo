#!/usr/bin/env bash
# Verifier for "Zero-Downtime Rollout". Inspects the live Deployment; prints the
# flag only when every rollout-safety check passes. Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-rollout
FLAG='KUBE{rollout_adds_before_it_removes}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get deploy web >/dev/null 2>&1 || fail "Deployment 'web' not found in $NS — run setup.sh first"

# (1a) strategy must be RollingUpdate (Recreate drops to zero on purpose).
STYPE=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.strategy.type}' 2>/dev/null)
[ "$STYPE" = "RollingUpdate" ] || fail "strategy.type must be RollingUpdate (found: ${STYPE:-unset})"

# (1b) maxUnavailable must be exactly 0 (not 0%, not 25%, not unset).
MAXU=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.strategy.rollingUpdate.maxUnavailable}' 2>/dev/null)
[ "$MAXU" = "0" ] || fail "rolling update must set maxUnavailable: 0 (found: ${MAXU:-unset}) — '0%' and 25% are rejected"

# (1c) maxSurge must be >= 1, or a maxUnavailable:0 rollout can never make progress.
MAXS=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.strategy.rollingUpdate.maxSurge}' 2>/dev/null)
case "$MAXS" in
  ''|'0'|'0%') fail "maxSurge must be >= 1 (found: ${MAXS:-unset}) — with maxUnavailable:0 a zero surge means the rollout is wedged forever" ;;
esac

# (2) a readinessProbe must be present on the container.
PROBE=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' 2>/dev/null)
[ -n "$PROBE" ] || fail "container needs a readinessProbe — without it a pod is 'Ready' before it can serve"

# (3) minReadySeconds must be >= 5 (soak time before the rollout advances).
MINRS=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.minReadySeconds}' 2>/dev/null)
if ! [ "${MINRS:-0}" -ge 5 ] 2>/dev/null; then
  fail "minReadySeconds must be >= 5 (found: ${MINRS:-0}) — a new pod must stay Ready before it counts"
fi

# (4) the Deployment must be fully rolled out: readyReplicas == spec.replicas.
SPEC=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.replicas}' 2>/dev/null)
READY=$(kubectl -n "$NS" get deploy web -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${SPEC:-0}" -ge 1 ] 2>/dev/null; then
  fail "spec.replicas must be >= 1 (found: ${SPEC:-unset}) — don't scale the service to zero"
fi
if [ "${READY:-0}" != "$SPEC" ]; then
  fail "not fully rolled out: readyReplicas=${READY:-0} but spec.replicas=$SPEC — is your readinessProbe passing? try 'kubectl -n $NS rollout status deploy/web'"
fi

echo "✓ strategy.type            : RollingUpdate"
echo "✓ maxUnavailable           : 0"
echo "✓ maxSurge                 : $MAXS"
echo "✓ readinessProbe present   : yes"
echo "✓ minReadySeconds          : $MINRS"
echo "✓ readyReplicas == replicas: $READY/$SPEC"
echo
echo "This Deployment now adds a ready, soaked pod before it ever evicts an old one."
echo "Submit this flag in the platform:"
echo
echo "    $FLAG"
