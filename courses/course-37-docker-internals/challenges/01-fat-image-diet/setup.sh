#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-docker-diet"
IMAGE="dojo/fat-image:1.0"
TMPDIR_BUILD="$(mktemp -d)"

cleanup() { rm -rf "$TMPDIR_BUILD"; }
trap cleanup EXIT

echo "==> Setting up challenge 01-fat-image-diet"
echo ""

# Create namespace (idempotent)
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Write app files to temp dir
cat > "$TMPDIR_BUILD/package.json" << 'PKGJSON'
{
  "name": "dojo-app",
  "version": "1.0.0",
  "dependencies": {
    "express": "4.18.2"
  },
  "scripts": {
    "start": "node server.js"
  }
}
PKGJSON

cat > "$TMPDIR_BUILD/package-lock.json" << 'LOCKJSON'
{
  "name": "dojo-app",
  "version": "1.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "dojo-app",
      "version": "1.0.0",
      "dependencies": { "express": "4.18.2" }
    }
  }
}
LOCKJSON

cat > "$TMPDIR_BUILD/server.js" << 'SERVERJS'
const express = require('express');
const app = express();
app.get('/', (req, res) => res.send('Hello from dojo!'));
app.listen(3000, () => console.log('Running on :3000'));
SERVERJS

cat > "$TMPDIR_BUILD/README.md" << 'READMEFILE'
# Dojo App
A sample Node.js app.
READMEFILE

# The WRONG Dockerfile — source copied before package install
cat > "$TMPDIR_BUILD/Dockerfile" << 'DOCKERFILE'
FROM node:20-slim
WORKDIR /app
COPY . .
RUN npm ci --omit=dev
EXPOSE 3000
LABEL docker.dojo.flag="KUBE{layer_order_saves_rebuild_time}"
LABEL docker.dojo.hint="Layer order matters: stable things should come before volatile things"
CMD ["node", "server.js"]
DOCKERFILE

echo "==> Building fat image (wrong layer order)..."
docker build -t "$IMAGE" "$TMPDIR_BUILD" --quiet

# Store the broken Dockerfile as a ConfigMap so learners can read it
kubectl create configmap broken-dockerfile \
  --from-file=Dockerfile="$TMPDIR_BUILD/Dockerfile" \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "✓ Namespace:  $NAMESPACE"
echo "✓ Image:      $IMAGE (built on host Docker daemon)"
echo "✓ ConfigMap:  broken-dockerfile (inspect it: kubectl get cm broken-dockerfile -n $NAMESPACE -o yaml)"
echo ""
echo "The image is built. Something interesting is hiding in its metadata."
echo "Start by looking at: docker history $IMAGE"
