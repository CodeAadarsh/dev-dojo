#!/usr/bin/env bash
# Installs the ingress-nginx controller tuned for kind. The kind-config maps
# host ports 8080/8443 -> container 80/443 on the ingress-ready control-plane,
# so Ingress resources become reachable at http://localhost:8080.
set -euo pipefail

echo "Installing ingress-nginx (kind variant)…"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

echo "Waiting for the controller to be ready (up to 3 min)…"
kubectl -n ingress-nginx wait --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s

echo "✓ ingress-nginx ready. Ingress hosts are reachable at http://localhost:8080"
