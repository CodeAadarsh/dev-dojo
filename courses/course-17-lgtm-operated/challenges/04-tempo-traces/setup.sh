#!/usr/bin/env bash
# Sets up the dojo-lgtm namespace and Grafana Helm repo for the Tempo challenge.
set -euo pipefail

NS=dojo-lgtm

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

echo "→ Creating namespace '$NS' (idempotent)..."
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "→ Adding Grafana Helm repo..."
if helm repo list 2>/dev/null | grep -q 'https://grafana.github.io/helm-charts'; then
  echo "  grafana repo already present — updating..."
  helm repo update grafana 2>/dev/null || helm repo update
else
  helm repo add grafana https://grafana.github.io/helm-charts
  helm repo update
fi

echo
echo "✓ Environment ready."
echo
echo "  Your task: install Grafana Tempo into namespace '$NS' with the OTLP"
echo "  receiver enabled. The Helm release MUST be named 'tempo'."
echo
echo "  Quick start:"
echo "    helm show values grafana/tempo | grep -A10 receivers"
echo "    helm install tempo grafana/tempo -n $NS \\"
echo "      --set tempo.receivers.otlp.protocols.grpc.endpoint=0.0.0.0:4317 \\"
echo "      --set tempo.receivers.otlp.protocols.http.endpoint=0.0.0.0:4318"
echo
echo "  When done, run the verifier:"
echo "    bash courses/course-17-lgtm-operated/challenges/04-tempo-traces/verify.sh"
