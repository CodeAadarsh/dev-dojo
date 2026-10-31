#!/usr/bin/env bash
# Stands up a local Docker registry and wires it into the kind network so the
# cluster can pull images you build locally (an alternative to `kind load`).
# Based on the official kind "local registry" pattern.
set -euo pipefail

reg_name='kind-registry'
reg_port='5001'

# 1. start the registry container if not already running
if [ "$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)" != 'true' ]; then
  echo "Starting local registry '${reg_name}' on localhost:${reg_port}…"
  docker run -d --restart=always -p "127.0.0.1:${reg_port}:5000" --name "${reg_name}" registry:2
else
  echo "Registry '${reg_name}' already running."
fi

# 2. connect it to the kind network so nodes can reach it
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${reg_name}" 2>/dev/null)" = 'null' ]; then
  docker network connect kind "${reg_name}" 2>/dev/null || true
fi

# 3. tell containerd on each node that localhost:5001 maps to the registry
for node in $(kind get nodes --name dojo 2>/dev/null); do
  docker exec "${node}" mkdir -p "/etc/containerd/certs.d/localhost:${reg_port}"
  cat <<EOF | docker exec -i "${node}" cp /dev/stdin "/etc/containerd/certs.d/localhost:${reg_port}/hosts.toml"
[host."http://${reg_name}:5000"]
EOF
done

echo "✓ Local registry ready at localhost:${reg_port}."
echo "  Use it:  docker tag myapp:dev localhost:${reg_port}/myapp:dev && docker push localhost:${reg_port}/myapp:dev"
echo "  Then reference image: localhost:${reg_port}/myapp:dev in your manifests."
echo "  (Simpler alternative for one-off images: kind load docker-image myapp:dev --name dojo)"
