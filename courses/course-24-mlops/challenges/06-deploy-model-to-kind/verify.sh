#!/usr/bin/env bash
# Verifier for "Deploy Model to kind".
# Checks namespace, Deployment readiness, image, and readinessProbe.
# Prints the flag only when every check passes.
set -uo pipefail

NS="dojo-mlops"
DEPLOY="model-server"
EXPECTED_IMAGE="dojo-model-server:v1"
FLAG='KUBE{model_deployed_to_kind}'

fail() { echo "✗ $1"; exit 1; }

# ── context guard ────────────────────────────────────────────────────────────
CURRENT_CTX="$(kubectl config current-context 2>/dev/null || true)"
if [ "$CURRENT_CTX" != "kind-dojo" ]; then
    echo "WARNING: current context is '$CURRENT_CTX', expected 'kind-dojo'."
    echo "         Run: kubectl config use-context kind-dojo"
fi

# ── 1. namespace exists ──────────────────────────────────────────────────────
kubectl get namespace "$NS" >/dev/null 2>&1 \
    || fail "namespace '$NS' does not exist — create it with: kubectl create ns $NS"

echo "✔ namespace $NS exists"

# ── 2. deployment exists ─────────────────────────────────────────────────────
kubectl -n "$NS" get deployment "$DEPLOY" >/dev/null 2>&1 \
    || fail "Deployment '$DEPLOY' not found in namespace '$NS'"

echo "✔ Deployment $DEPLOY found"

# ── 3. readyReplicas >= 1 ────────────────────────────────────────────────────
READY="$(kubectl -n "$NS" get deployment "$DEPLOY" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"

[ "${READY:-0}" -ge 1 ] \
    || fail "Deployment '$DEPLOY' has no ready replicas (readyReplicas=${READY:-0}) — check: kubectl -n $NS describe deployment $DEPLOY"

echo "✔ readyReplicas=$READY (>= 1)"

# ── 4. image matches ─────────────────────────────────────────────────────────
ACTUAL_IMAGE="$(kubectl -n "$NS" get deployment "$DEPLOY" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo '')"

[ "$ACTUAL_IMAGE" = "$EXPECTED_IMAGE" ] \
    || fail "expected image '$EXPECTED_IMAGE', got '$ACTUAL_IMAGE' — update deployment.yaml and re-apply"

echo "✔ image = $ACTUAL_IMAGE"

# ── 5. readinessProbe.httpGet.path == /healthz ───────────────────────────────
PROBE_PATH="$(kubectl -n "$NS" get deployment "$DEPLOY" \
    -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null || echo '')"

[ "$PROBE_PATH" = "/healthz" ] \
    || fail "readinessProbe.httpGet.path must be '/healthz', got '$PROBE_PATH' — add a readinessProbe to the container spec"

echo "✔ readinessProbe.httpGet.path = $PROBE_PATH"

# ── 6. imagePullPolicy = IfNotPresent ────────────────────────────────────────
PULL_POLICY="$(kubectl -n "$NS" get deployment "$DEPLOY" \
    -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}' 2>/dev/null || echo '')"

[ "$PULL_POLICY" = "IfNotPresent" ] \
    || fail "imagePullPolicy must be 'IfNotPresent' (kind nodes won't pull from a registry), got '$PULL_POLICY'"

echo "✔ imagePullPolicy = IfNotPresent"

echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
