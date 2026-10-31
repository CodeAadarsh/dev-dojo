#!/usr/bin/env bash
# Verifier for "Deploy to kind".
# Uses kubectl (no jq) to inspect cluster state; port-forwards to probe /health.
set -uo pipefail

NAMESPACE="dojo-fastapi"
DEPLOY="fastapi-dojo"
FLAG='KUBE{fastapi_shipped_to_kind_cluster}'

fail() { echo "✗ $1"; exit 1; }
pass() { echo "✓ $1"; }

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"

# ── 0. Context guard ─────────────────────────────────────────────────────────
CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "none")
if [ "$CURRENT_CTX" != "kind-dojo" ]; then
    echo "⚠  current context is '$CURRENT_CTX', not 'kind-dojo'"
    echo "   Run: kubectl config use-context kind-dojo"
    fail "wrong kubectl context"
fi

# ── 1. Namespace exists ──────────────────────────────────────────────────────
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
    || fail "namespace '$NAMESPACE' not found — create it and apply manifests"
pass "namespace $NAMESPACE exists"

# ── 2. Deployment exists ─────────────────────────────────────────────────────
kubectl get deployment "$DEPLOY" -n "$NAMESPACE" >/dev/null 2>&1 \
    || fail "deployment '$DEPLOY' not found in namespace '$NAMESPACE'"
pass "deployment $DEPLOY found"

# ── 3. Deployment has at least one available replica ─────────────────────────
AVAIL=$(kubectl get deployment "$DEPLOY" -n "$NAMESPACE" \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
[ "${AVAIL:-0}" -ge 1 ] \
    || fail "deployment '$DEPLOY' has 0 available replicas — check: kubectl describe deployment $DEPLOY -n $NAMESPACE"
pass "deployment has $AVAIL available replica(s)"

# ── 4. readOnlyRootFilesystem: true ──────────────────────────────────────────
ROFS=$(kubectl get deployment "$DEPLOY" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem}' \
    2>/dev/null || echo "false")
[ "$ROFS" = "true" ] \
    || fail "readOnlyRootFilesystem is not true — add securityContext.readOnlyRootFilesystem: true to the container spec"
pass "readOnlyRootFilesystem: true"

# ── 5. runAsNonRoot: true ────────────────────────────────────────────────────
NONROOT=$(kubectl get deployment "$DEPLOY" -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].securityContext.runAsNonRoot}' \
    2>/dev/null || echo "false")
[ "$NONROOT" = "true" ] \
    || fail "runAsNonRoot is not true — add securityContext.runAsNonRoot: true to the container spec"
pass "runAsNonRoot: true"

# ── 6. /health responds 200 via port-forward ─────────────────────────────────
LOCAL_PORT=18432
# clean up any leftover port-forward from a previous run
pkill -f "kubectl port-forward.*$LOCAL_PORT" 2>/dev/null || true

kubectl port-forward -n "$NAMESPACE" svc/"$DEPLOY" "$LOCAL_PORT":80 \
    >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT

# give port-forward time to establish
TRIES=0
until curl -s --max-time 2 "http://localhost:$LOCAL_PORT/health" >/dev/null 2>&1; do
    TRIES=$((TRIES + 1))
    [ "$TRIES" -ge 10 ] && fail "/health did not respond after 10 attempts — is the service selector correct?"
    sleep 1
done

HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$LOCAL_PORT/health")
[ "$HTTP_STATUS" = "200" ] \
    || fail "GET /health returned HTTP $HTTP_STATUS, expected 200"
pass "GET /health returned 200"

echo
echo "All deployment checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
