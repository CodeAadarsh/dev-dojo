#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-docker-platform"
FLAG="KUBE{buildx_platform_linux_amd64}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

echo "==> Verifying 05-cross-platform..."

kubectl get deployment api -n "$NAMESPACE" > /dev/null 2>&1 \
  || fail "Deployment 'api' not found in namespace $NAMESPACE"

POD=$(kubectl get pod -n "$NAMESPACE" -l app=api \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$POD" ] || fail "No pods found for label app=api in $NAMESPACE"

PHASE=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
[ "$PHASE" = "Running" ] || fail "Pod $POD is in phase '$PHASE', expected Running — did you build with --platform linux/amd64, kind load, and kubectl set image?"

ANNOTATION=$(kubectl get deployment api -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.dojo\.docker/fixed-platform}' 2>/dev/null || true)
[ "$ANNOTATION" = "linux/amd64" ] \
  || fail "Missing annotation dojo.docker/fixed-platform=linux/amd64 — run: kubectl annotate deployment api dojo.docker/fixed-platform=linux/amd64 -n $NAMESPACE"

echo "✓ Deployment api exists"
echo "✓ Pod $POD is Running"
echo "✓ Annotation dojo.docker/fixed-platform=linux/amd64 present"
echo ""
echo "Flag: $FLAG"
