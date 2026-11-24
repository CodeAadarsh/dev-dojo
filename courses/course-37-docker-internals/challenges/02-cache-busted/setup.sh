#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-docker-cache"

echo "==> Setting up challenge 02-cache-busted"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# The broken Dockerfile — COPY . . before RUN npm ci
kubectl create configmap broken-dockerfile \
  --from-literal=Dockerfile='FROM node:20-slim
WORKDIR /app
COPY . .
RUN npm ci --omit=dev
EXPOSE 3000
CMD ["node", "server.js"]' \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

# App source for reference
kubectl create configmap app-source \
  --from-literal=package.json='{"name":"dojo-app","version":"1.0.0","dependencies":{"express":"4.18.2"}}' \
  --from-literal=server.js='const express = require("express"); const app = express(); app.get("/", (_, res) => res.send("hello")); app.listen(3000);' \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "✓ Namespace: $NAMESPACE"
echo "✓ ConfigMap: broken-dockerfile"
echo "✓ ConfigMap: app-source"
echo ""
echo "Read the broken Dockerfile:"
echo "  kubectl get configmap broken-dockerfile -n $NAMESPACE -o jsonpath='{.data.Dockerfile}'"
echo ""
echo "Fix it and store your corrected version as ConfigMap 'fixed-dockerfile' in namespace $NAMESPACE."
echo "  kubectl create configmap fixed-dockerfile --from-literal=Dockerfile='...' -n $NAMESPACE"
