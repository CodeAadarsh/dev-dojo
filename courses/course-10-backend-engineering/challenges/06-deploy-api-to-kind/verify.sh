#!/usr/bin/env bash
# Verifier for "Deploy API to kind" (bridge challenge).
# Builds the image, loads it into the dojo kind cluster, then checks the
# Deployment + Service are healthy and /healthz responds 200.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/06-deploy-api-to-kind"
NS="dojo-backend"
IMG="dojo-api:v1"
FLAG='KUBE{ship_it_to_kind}'

fail() { echo "✗ $1"; exit 1; }

command -v docker >/dev/null 2>&1 || fail "docker not found — install Docker Desktop"
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v kind >/dev/null 2>&1 || fail "kind not found"

[[ -d "$WORK" ]] || fail "work directory not found — run setup.sh first"
cd "$WORK"
[[ -f "Dockerfile" ]] || fail "Dockerfile missing — run setup.sh again"

echo "Building $IMG ..."
docker build -t "$IMG" . || fail "docker build failed — check Dockerfile and app.py in $WORK"

echo "Loading $IMG into kind cluster 'dojo' ..."
kind load docker-image "$IMG" --name dojo || fail "kind load failed — is the 'dojo' cluster running? (kind create cluster --name dojo)"

kubectl create namespace "$NS" --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - 2>/dev/null || true

DEPLOY=$(kubectl -n "$NS" get deploy -o name 2>/dev/null | head -1)
[[ -n "${DEPLOY:-}" ]] || fail "no Deployment in namespace $NS — apply your manifest: kubectl apply -f $WORK/deploy.yaml"

IMAGE=$(kubectl -n "$NS" get "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
echo "$IMAGE" | grep -q "dojo-api" || fail "Deployment image '$IMAGE' does not contain 'dojo-api' — did you replace FILL_IN with dojo-api:v1 in deploy.yaml?"

READY=$(kubectl -n "$NS" get "$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[[ "${READY:-0}" -ge 1 ]] || fail "Deployment has no ready replicas (readyReplicas=${READY:-0}) — check: kubectl -n $NS describe $DEPLOY"

POD=$(kubectl -n "$NS" get pod -l app=dojo-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -n "${POD:-}" ]] || fail "no pod with label app=dojo-api in $NS — does your Deployment template have labels.app=dojo-api?"

PF_PID=""
cleanup() { [[ -n "${PF_PID:-}" ]] && kill "$PF_PID" 2>/dev/null; }
trap cleanup EXIT

echo "Port-forwarding $POD:5000 -> localhost:18080 ..."
kubectl -n "$NS" port-forward "$POD" 18080:5000 >/dev/null 2>&1 &
PF_PID=$!
sleep 2

HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --retry 5 --retry-delay 1 --retry-connrefused http://localhost:18080/healthz)
[[ "$HTTP_STATUS" = "200" ]] || fail "/healthz returned HTTP $HTTP_STATUS (expected 200) — is Flask bound to 0.0.0.0:5000, not 127.0.0.1?"

echo "✓ Docker image built            : $IMG"
echo "✓ Loaded into kind cluster      : dojo"
echo "✓ Deployment found              : $DEPLOY"
echo "✓ Deployment image tag          : $IMAGE"
echo "✓ Ready replicas                : $READY"
echo "✓ /healthz response             : HTTP $HTTP_STATUS"
echo
echo "All deployment checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
