#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-docker-signing"
REGISTRY_NAME="dojo-signing-registry"
REGISTRY_PORT="5001"

echo "==> Setting up challenge: Image Signing"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Start a local registry (idempotent)
if ! docker ps --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
  echo "    Starting local registry on port ${REGISTRY_PORT}..."
  docker run -d \
    -p "${REGISTRY_PORT}:5000" \
    --name "$REGISTRY_NAME" \
    registry:2.8.3
  sleep 2
else
  echo "    Registry ${REGISTRY_NAME} already running."
fi

# Push an unsigned image
docker tag nginx:1.27-alpine "localhost:${REGISTRY_PORT}/dojo/api:1.0"
docker push "localhost:${REGISTRY_PORT}/dojo/api:1.0"

# Check cosign
if ! command -v cosign >/dev/null 2>&1; then
  echo ""
  echo "    WARNING: cosign is not installed."
  echo "    Install it first:"
  echo "      macOS : brew install cosign"
  echo "      Linux : https://github.com/sigstore/cosign/releases"
  echo ""
fi

# Deploy into k8s (imagePullPolicy: Never since registry is on host)
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: ${NAMESPACE}
  annotations:
    dojo.docker/signed: "false"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
      - name: api
        image: nginx:1.27-alpine
        imagePullPolicy: IfNotPresent
EOF

echo ""
echo "==> Scenario planted."
echo ""
echo "    Registry  : localhost:${REGISTRY_PORT}"
echo "    Image     : localhost:${REGISTRY_PORT}/dojo/api:1.0  (unsigned)"
echo "    Namespace : ${NAMESPACE}"
echo ""
echo "    Your job  :"
echo "      1. cosign generate-key-pair"
echo "      2. COSIGN_INSECURE_IGNORE_TLOG=true cosign sign --key cosign.key \\"
echo "             --allow-insecure-registry localhost:${REGISTRY_PORT}/dojo/api:1.0"
echo "      3. kubectl annotate deployment api dojo.docker/signed=true -n ${NAMESPACE}"
echo ""
echo "    When done : bash courses/course-37-docker-internals/challenges/13-image-signing/verify.sh"
