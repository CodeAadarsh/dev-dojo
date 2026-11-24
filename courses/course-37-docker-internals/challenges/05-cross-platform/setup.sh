#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-docker-platform"

echo "==> Setting up challenge 05-cross-platform"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# A Dockerfile for a simple nginx-based app the learner will rebuild for amd64
kubectl create configmap api-dockerfile \
  --from-literal=Dockerfile='FROM nginx:1.27-alpine
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
# Build this for linux/amd64:
#   docker buildx build --platform linux/amd64 -t dojo/api:amd64-fixed . --load' \
  --from-literal=index.html='<!DOCTYPE html><html><body><h1>API v2 — running on amd64</h1></body></html>' \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

# Broken deployment using a non-existent arm64-only image
kubectl apply -f - << 'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: dojo-docker-platform
  labels:
    app: api
  annotations:
    dojo.docker/original-platform: "linux/arm64"
    dojo.docker/problem: "image was built for arm64 — cluster nodes run amd64"
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
          image: dojo/api:arm64-only
          imagePullPolicy: Never
YAML

echo ""
echo "✓ Namespace: $NAMESPACE"
echo "✓ Deployment: api (broken — image dojo/api:arm64-only does not exist)"
echo ""
echo "Get the Dockerfile to build from:"
echo "  kubectl get configmap api-dockerfile -n $NAMESPACE -o jsonpath='{.data.Dockerfile}'"
echo ""
echo "Build with: docker buildx build --platform linux/amd64 -t dojo/api:amd64-fixed . --load"
