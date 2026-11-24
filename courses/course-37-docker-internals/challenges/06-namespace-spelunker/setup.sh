#!/usr/bin/env bash
set -euo pipefail

CONTAINER="dojo-spelunker"

echo "==> Setting up challenge 06-namespace-spelunker"

# Remove existing container if present (idempotent)
docker rm -f "$CONTAINER" 2>/dev/null || true

# Start container in background
docker run -d \
  --name "$CONTAINER" \
  alpine:3.20 \
  sleep 7200

# Plant the flag inside the container
docker exec "$CONTAINER" sh -c "mkdir -p /secret && printf '%s' 'KUBE{namespaces_isolate_kernel_views}' > /secret/flag.txt"

echo ""
echo "✓ Container '$CONTAINER' is running"
echo ""
echo "Rules:"
echo "  - Do NOT use: docker exec $CONTAINER"
echo "  - Use nsenter to enter the container's mount namespace"
echo ""
echo "Start with:"
echo "  docker inspect $CONTAINER --format '{{.State.Pid}}'"
