#!/usr/bin/env bash
# Verifier for "Dockerize & Deploy — FastAPI to kind".
# Checks kubectl state only — no jq, POSIX tools + jsonpath only.
# Prints the flag when:
#   1. Deployment fastapi in dojo-fastapi exists and readyReplicas >= 1
#   2. The pod image contains dojo-fastapi:v1
#   3. The container has a readinessProbe with httpGet.path = /health
set -uo pipefail

FLAG='KUBE{image_loaded_and_deployed_to_dojo}'

fail() { echo "✗ $1"; exit 1; }

# ── context check ─────────────────────────────────────────────────────────────
CTX="$(kubectl config current-context 2>/dev/null || echo '')"
if [ "$CTX" != "kind-dojo" ]; then
    echo "WARNING: current context is '$CTX', expected 'kind-dojo'."
    echo "         If you deployed to a different context the checks below may fail."
fi

# ── 1. Deployment exists and is ready ────────────────────────────────────────
echo "Checking Deployment fastapi in namespace dojo-fastapi..."

READY="$(kubectl get deployment fastapi -n dojo-fastapi \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo '0')"

[ -n "$READY" ] || fail "Deployment fastapi not found in namespace dojo-fastapi"
[ "$READY" -ge 1 ] 2>/dev/null || fail "Deployment fastapi has readyReplicas=$READY — expected >= 1. Wait a moment and retry."

echo "  readyReplicas=$READY  OK"

# ── 2. Pod image is dojo-fastapi:v1 ──────────────────────────────────────────
echo "Checking pod image..."

POD_IMAGE="$(kubectl get pods -n dojo-fastapi \
    -l app=fastapi \
    -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || echo '')"

[ -n "$POD_IMAGE" ] || fail "No pods with label app=fastapi found in dojo-fastapi"

if echo "$POD_IMAGE" | grep -q 'dojo-fastapi:v1'; then
    echo "  image=$POD_IMAGE  OK"
else
    fail "Pod image is '$POD_IMAGE', expected 'dojo-fastapi:v1'. Did you set image: dojo-fastapi:v1 in your Deployment?"
fi

# ── 3. readinessProbe with httpGet /health ────────────────────────────────────
echo "Checking readinessProbe..."

PROBE_PATH="$(kubectl get deployment fastapi -n dojo-fastapi \
    -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null || echo '')"

[ -n "$PROBE_PATH" ] || fail "No readinessProbe.httpGet.path found on container 'fastapi' — add a readinessProbe with httpGet.path=/health"

if [ "$PROBE_PATH" = "/health" ]; then
    echo "  readinessProbe.httpGet.path=$PROBE_PATH  OK"
else
    fail "readinessProbe.httpGet.path is '$PROBE_PATH', expected '/health'"
fi

# ── all checks passed ─────────────────────────────────────────────────────────
echo
echo "All deployment checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
