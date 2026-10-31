#!/usr/bin/env bash
# Verifier for "Drain Gracefully". Inspects live cluster state; prints the flag
# only when the Deployment drains cleanly on termination. Exit 0 = solved,
# 1 = not yet. Uses only kubectl + POSIX tools (no jq).
set -uo pipefail

NS=dojo-grace
FLAG='KUBE{prestop_drains_before_sigterm}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get deploy web >/dev/null 2>&1 || fail "Deployment 'web' not found in $NS — run setup.sh first"

# (1) a preStop hook must exist on the container.
PRESTOP=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.template.spec.containers[0].lifecycle.preStop}' 2>/dev/null)
[ -n "$PRESTOP" ] || fail "container needs a lifecycle.preStop hook to stall SIGTERM while endpoints drain"

# Extract the sleep duration from an exec preStop like ["/bin/sh","-c","sleep 15"].
# jsonpath [*] joins the command args with spaces; grab the first bare integer.
PRESTOP_CMD=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.template.spec.containers[0].lifecycle.preStop.exec.command[*]}' 2>/dev/null)
SLEEP=$(printf '%s\n' "$PRESTOP_CMD" | awk '{for(i=1;i<=NF;i++){if($i ~ /^[0-9]+$/){print $i; exit}}}')

# (2) terminationGracePeriodSeconds must be set and cover the preStop sleep.
GRACE=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}' 2>/dev/null)
if ! [ "${GRACE:-0}" -ge 1 ] 2>/dev/null; then
  fail "terminationGracePeriodSeconds is not set to a positive value (found: ${GRACE:-unset})"
fi

if [ -n "$SLEEP" ]; then
  if ! [ "$SLEEP" -ge 5 ] 2>/dev/null; then
    fail "the preStop sleep is ${SLEEP}s — too short to drain anything; use >= 5s (brief suggests 15)"
  fi
  if ! [ "$GRACE" -ge "$SLEEP" ] 2>/dev/null; then
    fail "terminationGracePeriodSeconds ($GRACE) must be >= the preStop sleep ($SLEEP), or the kubelet SIGKILLs mid-drain"
  fi
else
  # Non-exec preStop (e.g. httpGet): can't read a sleep value, so require a
  # grace period long enough to be meaningful for draining.
  if ! [ "$GRACE" -ge 15 ] 2>/dev/null; then
    fail "with a non-sleep preStop, terminationGracePeriodSeconds must be >= 15 to allow draining (found: $GRACE)"
  fi
fi

# (3) a readinessProbe must be present.
PROBE=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' 2>/dev/null)
[ -n "$PROBE" ] || fail "container needs a readinessProbe so the endpoint controller can rotate the pod in/out cleanly"

# (4) at least one pod actually rolled out and reached Ready with the new spec.
READY=$(kubectl -n "$NS" get deploy web -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${READY:-0}" -ge 1 ] 2>/dev/null; then
  fail "no pods are Ready (found: ${READY:-0}) — is the rollout complete and the readinessProbe passing?"
fi

echo "✓ lifecycle.preStop present       : yes"
if [ -n "$SLEEP" ]; then
  echo "✓ preStop sleep                   : ${SLEEP}s"
fi
echo "✓ terminationGracePeriodSeconds   : ${GRACE}s (>= preStop drain)"
echo "✓ readinessProbe present          : yes"
echo "✓ pods Ready                      : $READY"
echo
echo "The pod now leaves rotation, drains, then exits cleanly — no reset storms on deploy."
echo "Submit this flag in the platform:"
echo
echo "    $FLAG"
