#!/usr/bin/env bash
# Verifier for "Ship It: Gunicorn + Docker + k8s".
# Checks namespace, Deployment readiness, image name, and readinessProbe on /health.
set -uo pipefail

FLAG='KUBE{gunicorn_serves_production}'

fail() { echo "✗ $1"; exit 1; }

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v kind >/dev/null 2>&1 || fail "kind not found"

echo "Checking namespace dojo-flask..."
kubectl get namespace dojo-flask >/dev/null 2>&1 || \
    fail "namespace dojo-flask not found — create it and apply your manifests"

echo "Checking Deployment in dojo-flask..."
DEPLOY_NAME=$(kubectl get deployments -n dojo-flask -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$DEPLOY_NAME" ] || fail "no Deployment found in namespace dojo-flask"

READY=$(kubectl get deployment "$DEPLOY_NAME" -n dojo-flask \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
[ "${READY:-0}" -ge 1 ] || \
    fail "Deployment '$DEPLOY_NAME' has no ready replicas (got ${READY:-0}) — check: kubectl describe deployment $DEPLOY_NAME -n dojo-flask"

echo "Checking image name contains 'flask-app'..."
IMAGE=$(kubectl get deployment "$DEPLOY_NAME" -n dojo-flask \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
echo "$IMAGE" | grep -q 'flask-app' || \
    fail "container image '$IMAGE' does not contain 'flask-app' — rebuild with: docker build -t flask-app:dojo ."

echo "Checking readinessProbe on /health..."
PROBE_PATH=$(kubectl get deployment "$DEPLOY_NAME" -n dojo-flask \
    -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null || true)
[ "$PROBE_PATH" = "/health" ] || \
    fail "readinessProbe httpGet path is '$PROBE_PATH', expected '/health' — add a readinessProbe to your Deployment spec"

echo
echo "All checks passed. Submit this flag:"
echo
echo "    $FLAG"
