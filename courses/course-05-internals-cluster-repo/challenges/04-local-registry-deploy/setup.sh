#!/usr/bin/env bash
# Plants the "Ship From Your Own Registry" scenario. This challenge is driven by
# the learner (build→tag→push→deploy), so setup only creates the namespace and
# explains the prerequisite. It deliberately does NOT deploy anything — the
# whole point is that you push an image to localhost:5001 and deploy it yourself.
set -euo pipefail

NS=dojo-registry

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo
echo "✓ Namespace '$NS' is ready (no workload planted — you build and ship it)."
echo
echo "Step 0 — stand up the local registry (run once):"
echo "    bash labs/bootstrap/install-registry.sh"
echo
echo "Then run the loop:"
echo "    docker pull nginx:1.27-alpine"
echo "    docker tag  nginx:1.27-alpine localhost:5001/web:v1"
echo "    docker push localhost:5001/web:v1"
echo
echo "Finally, deploy an image that references localhost:5001/ into '$NS',"
echo "get it Ready, then run verify.sh."
