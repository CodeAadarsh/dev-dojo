#!/usr/bin/env bash
# Verifier for "Serve RAG on Kubernetes".
# Checks: namespace dojo-genai exists, a Deployment has readyReplicas >= 1,
# and the container image is rag-service:v1.
# No jq. Uses kubectl -o jsonpath throughout.
set -uo pipefail

NS="dojo-genai"
EXPECTED_IMAGE="rag-service:v1"
FLAG='KUBE{rag_on_k8s_context_over_the_wire}'

fail() { echo "✗ $1"; exit 1; }

# ── preflight ─────────────────────────────────────────────────────────────────
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"

CTX=$(kubectl config current-context 2>/dev/null || true)
if [ "$CTX" != "kind-dojo" ]; then
    echo "  warning: current context is '$CTX', expected 'kind-dojo'"
    echo "           run: kubectl config use-context kind-dojo"
fi

# ── namespace ─────────────────────────────────────────────────────────────────
kubectl get namespace "$NS" >/dev/null 2>&1 \
    || fail "namespace '$NS' not found — run: kubectl create namespace $NS"

# ── deployment ────────────────────────────────────────────────────────────────
DEPLOY=$(kubectl get deployment -n "$NS" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$DEPLOY" ] \
    || fail "no Deployment found in namespace '$NS' — did you run 'kubectl apply -f k8s/'?"

# ── ready replicas ────────────────────────────────────────────────────────────
READY=$(kubectl get deployment -n "$NS" "$DEPLOY" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
[ -n "$READY" ] \
    || fail "deployment '$DEPLOY' has no readyReplicas yet — check: kubectl get pods -n $NS"
[ "$READY" -ge 1 ] \
    || fail "deployment '$DEPLOY' readyReplicas=$READY, need >= 1 — check: kubectl describe deployment/$DEPLOY -n $NS"

# ── image ─────────────────────────────────────────────────────────────────────
DEPLOY_IMG=$(kubectl get deployment -n "$NS" "$DEPLOY" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')
[ "$DEPLOY_IMG" = "$EXPECTED_IMAGE" ] \
    || fail "deployment uses image '$DEPLOY_IMG', expected '$EXPECTED_IMAGE' — did you build and load the image with the correct tag?"

# ── all checks passed ─────────────────────────────────────────────────────────
echo
echo "Namespace '$NS'   : found"
echo "Deployment        : $DEPLOY"
echo "Ready replicas    : $READY"
echo "Container image   : $DEPLOY_IMG"
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
