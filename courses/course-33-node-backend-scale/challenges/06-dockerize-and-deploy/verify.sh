#!/usr/bin/env bash
# Verifier for "Dockerize and Deploy to Kubernetes".
# Checks cluster state with kubectl; no jq used.
set -uo pipefail

NAMESPACE="dojo-node"
DEPLOY="dojo-node-api"
IMAGE="dojo-node-api:1.0.0"
FLAG='KUBE{ship_it_to_the_cluster}'

fail() { echo "✗ $1"; exit 1; }

# ── prereq: right context ─────────────────────────────────────────────────────
CTX=$(kubectl config current-context 2>/dev/null || true)
if [ "$CTX" != "kind-dojo" ]; then
  echo "WARNING: current context is '$CTX', expected 'kind-dojo'"
  echo "         run: kubectl config use-context kind-dojo"
fi

# ── check 1: namespace exists ─────────────────────────────────────────────────
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
  || fail "namespace '$NAMESPACE' not found — create it: kubectl create namespace $NAMESPACE"

# ── check 2: deployment exists ───────────────────────────────────────────────
kubectl get deployment "$DEPLOY" -n "$NAMESPACE" >/dev/null 2>&1 \
  || fail "Deployment '$DEPLOY' not found in namespace '$NAMESPACE'"

# ── check 3: readyReplicas >= 1 ───────────────────────────────────────────────
READY=$(kubectl get deployment "$DEPLOY" -n "$NAMESPACE" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
READY="${READY:-0}"
[ "$READY" -ge 1 ] \
  || fail "Deployment '$DEPLOY' has 0 ready replicas (got '$READY') — check: kubectl describe deployment $DEPLOY -n $NAMESPACE"

# ── check 4: readinessProbe configured ───────────────────────────────────────
PROBE_PATH=$(kubectl get deployment "$DEPLOY" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null || echo "")
[ -n "$PROBE_PATH" ] \
  || fail "no httpGet readinessProbe found on the first container — add readinessProbe.httpGet.path=/health"

# ── check 5: non-root security context ───────────────────────────────────────
RUN_AS_NON_ROOT=$(kubectl get deployment "$DEPLOY" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.securityContext.runAsNonRoot}' 2>/dev/null || echo "")
RUN_AS_USER=$(kubectl get deployment "$DEPLOY" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.securityContext.runAsUser}' 2>/dev/null || echo "")
CONTAINER_NON_ROOT=$(kubectl get deployment "$DEPLOY" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].securityContext.runAsNonRoot}' 2>/dev/null || echo "")
CONTAINER_USER=$(kubectl get deployment "$DEPLOY" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].securityContext.runAsUser}' 2>/dev/null || echo "")

NON_ROOT_OK="false"
if [ "$RUN_AS_NON_ROOT" = "true" ] || [ "$CONTAINER_NON_ROOT" = "true" ]; then
  NON_ROOT_OK="true"
fi
if [ -n "$RUN_AS_USER" ] && [ "$RUN_AS_USER" != "0" ]; then
  NON_ROOT_OK="true"
fi
if [ -n "$CONTAINER_USER" ] && [ "$CONTAINER_USER" != "0" ]; then
  NON_ROOT_OK="true"
fi
[ "$NON_ROOT_OK" = "true" ] \
  || fail "pod security context does not enforce non-root — set securityContext.runAsNonRoot: true or runAsUser: 1000"

# ── check 6: correct image ────────────────────────────────────────────────────
ACTUAL_IMAGE=$(kubectl get deployment "$DEPLOY" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
[ "$ACTUAL_IMAGE" = "$IMAGE" ] \
  || fail "Deployment uses image '$ACTUAL_IMAGE', expected '$IMAGE'"

# ── all checks passed ─────────────────────────────────────────────────────────
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
