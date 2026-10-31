#!/usr/bin/env bash
# Installs the kube-prometheus-stack (Prometheus + Grafana + Alertmanager +
# node/kube-state metrics) via Helm — real production-grade observability infra.
#
# ⚠ RESOURCE WARNING: this stack wants ~2-3 GB of RAM on top of the cluster.
#   On an 8 GB machine, run it on a FRESH cluster without other heavy labs, and
#   expect Docker Desktop to need its memory limit raised (Settings → Resources).
set -euo pipefail

command -v helm >/dev/null 2>&1 || { echo "✗ helm is required (brew install helm)"; exit 1; }

echo "Adding prometheus-community Helm repo…"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

echo "Installing kube-prometheus-stack (pulls several images — first run is slow)…"
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n monitoring \
  --set grafana.adminPassword=admin \
  --set prometheus.prometheusSpec.resources.requests.memory=400Mi \
  --wait --timeout 12m

echo
echo "✓ Monitoring stack up."
echo "  Grafana:    kubectl -n monitoring port-forward svc/kps-grafana 3000:80        # admin / admin"
echo "  Prometheus: kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090"
echo "  Uninstall:  helm -n monitoring uninstall kps"
