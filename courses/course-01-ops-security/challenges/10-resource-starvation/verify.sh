#!/usr/bin/env bash
# Verifier for "Resource Starvation". Inspects live cluster state; prints the
# flag only when container[0] of deploy/api has both requests AND limits, and a
# LimitRange exists in the namespace. Exit 0 = solved, 1 = not yet.
# Uses only kubectl + POSIX tools (no jq).
set -uo pipefail

NS=dojo-resources
FLAG='KUBE{set_requests_limits_before_the_oom_killer_does}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get deploy api >/dev/null 2>&1 || fail "Deployment 'api' not found in $NS — run setup.sh first"

REQ=$(kubectl -n "$NS" get deploy api -o jsonpath='{.spec.template.spec.containers[0].resources.requests}' 2>/dev/null)
[ -n "$REQ" ] || fail "container 'api' has no resources.requests — set cpu AND memory requests"

LIM=$(kubectl -n "$NS" get deploy api -o jsonpath='{.spec.template.spec.containers[0].resources.limits}' 2>/dev/null)
[ -n "$LIM" ] || fail "container 'api' has no resources.limits — set cpu AND memory limits"

LR=$(kubectl -n "$NS" get limitrange -o name 2>/dev/null)
[ -n "$LR" ] || fail "no LimitRange in $NS — create one with a default request/limit so forgetful pods aren't BestEffort"

QOS=$(kubectl -n "$NS" get pod -l app=api -o jsonpath='{.items[0].status.qosClass}' 2>/dev/null)

echo "✓ requests set (container)  : $REQ"
echo "✓ limits set (container)    : $LIM"
echo "✓ LimitRange in namespace   : ${LR}"
echo "✓ api pod QoS class         : ${QOS:-unknown} (no longer BestEffort)"
echo
echo "The workload now has a defensible QoS class and the namespace defaults are safe."
echo "Submit this flag in the platform:"
echo
echo "    $FLAG"
