#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-docker-multistage"
FLAG="KUBE{distroless_binary_no_shell}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

echo "==> Verifying 04-multi-stage-go..."

kubectl get deployment go-app-slim -n "$NAMESPACE" > /dev/null 2>&1 \
  || fail "Deployment 'go-app-slim' not found in namespace $NAMESPACE"

POD=$(kubectl get pod -n "$NAMESPACE" -l app=go-app-slim \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$POD" ] || fail "No pods found for label app=go-app-slim in $NAMESPACE"

PHASE=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
[ "$PHASE" = "Running" ] || fail "Pod $POD is in phase '$PHASE', expected Running"

ANNOTATION=$(kubectl get deployment go-app-slim -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.dojo\.docker/build-type}' 2>/dev/null || true)
[ "$ANNOTATION" = "multi-stage" ] \
  || fail "Missing annotation dojo.docker/build-type=multi-stage on deployment go-app-slim — run: kubectl annotate deployment go-app-slim dojo.docker/build-type=multi-stage -n $NAMESPACE"

echo "✓ Deployment go-app-slim exists"
echo "✓ Pod $POD is Running"
echo "✓ Annotation dojo.docker/build-type=multi-stage present"
echo ""
echo "Flag: $FLAG"
