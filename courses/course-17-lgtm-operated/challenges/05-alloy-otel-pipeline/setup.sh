#!/usr/bin/env bash
# Sets up the dojo-lgtm namespace and Grafana Helm repo for the Alloy/OTel pipeline challenge.
set -euo pipefail

NS=dojo-lgtm

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

echo "→ Creating namespace '$NS' (idempotent)..."
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "→ Ensuring Grafana Helm repo is present..."
if helm repo list 2>/dev/null | grep -q 'https://grafana.github.io/helm-charts'; then
  helm repo update grafana 2>/dev/null || helm repo update
else
  helm repo add grafana https://grafana.github.io/helm-charts
  helm repo update
fi

echo
echo "✓ Environment ready."
echo
echo "  Your task: deploy Grafana Alloy (grafana/alloy) OR an OTel Collector"
echo "  into namespace '$NS' with a three-stage pipeline:"
echo "    OTLP receiver  →  batch/memory_limiter processor  →  exporter"
echo
echo "  Alloy quick start:"
echo "    helm show values grafana/alloy | grep -A5 configMap"
echo "    # create an alloy-values.yaml with alloy.configMap.content set to your"
echo "    # River pipeline config, then:"
echo "    helm install alloy grafana/alloy -n $NS -f alloy-values.yaml"
echo
echo "  Note: if you completed challenge 04, Tempo is already running in '$NS'."
echo "  You can export to it via otelcol.exporter.otlp pointing at"
echo "  tempo.dojo-lgtm.svc.cluster.local:4317"
echo
echo "  When done, run the verifier:"
echo "    bash courses/course-17-lgtm-operated/challenges/05-alloy-otel-pipeline/verify.sh"
