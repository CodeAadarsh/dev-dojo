#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-docker-bridge"

echo "==> Setting up challenge: Custom Bridge Isolation"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Create the shared (insecure) network
if ! docker network ls --format '{{.Name}}' | grep -q "^dojo-shared$"; then
  docker network create --driver bridge dojo-shared
  echo "    Created Docker network: dojo-shared"
else
  echo "    Docker network dojo-shared already exists."
fi

# Start containers on the shared network (idempotent)
if ! docker ps --format '{{.Names}}' | grep -q "^dojo-payments$"; then
  docker run -d --network dojo-shared --name dojo-payments nginx:1.27-alpine
  echo "    Started container: dojo-payments"
else
  echo "    Container dojo-payments already running."
fi

if ! docker ps --format '{{.Names}}' | grep -q "^dojo-internal-api$"; then
  docker run -d --network dojo-shared --name dojo-internal-api nginx:1.27-alpine
  echo "    Started container: dojo-internal-api"
else
  echo "    Container dojo-internal-api already running."
fi

# Create the proof ConfigMap (learner updates isolated_network field)
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: network-proof
  namespace: dojo-docker-bridge
data:
  isolated_network: "pending"
  instructions: "Update isolated_network to dojo-isolated after you have created it and moved dojo-internal-api to it"
EOF

echo ""
echo "==> Scenario planted."
echo ""
echo "    Docker containers : dojo-payments and dojo-internal-api"
echo "    Both on network   : dojo-shared  (insecure — they can talk)"
echo ""
echo "    Proof right now   :"
echo "      docker exec dojo-payments ping -c 2 dojo-internal-api  # succeeds"
echo ""
echo "    Your job  :"
echo "      1. docker network create --driver bridge dojo-isolated"
echo "      2. Move dojo-internal-api to dojo-isolated"
echo "      3. kubectl patch configmap network-proof -n dojo-docker-bridge \\"
echo "             -p '{\"data\":{\"isolated_network\":\"dojo-isolated\"}}'"
echo ""
echo "    When done : bash courses/course-37-docker-internals/challenges/14-custom-bridge/verify.sh"
