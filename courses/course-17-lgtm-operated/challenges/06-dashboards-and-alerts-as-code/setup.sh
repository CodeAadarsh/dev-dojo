#!/usr/bin/env bash
# Sets up the dojo-lgtm namespace and optionally installs Grafana for the
# dashboards-and-alerts-as-code challenge.
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

# Install Grafana with dashboard and alert sidecars if not already present.
# The sidecar containers watch for labeled ConfigMaps and provision them automatically.
if ! helm -n "$NS" list -q 2>/dev/null | grep -q '^grafana$'; then
  echo "→ Installing Grafana with dashboard + alert sidecars into '$NS'..."
  helm install grafana grafana/grafana \
    -n "$NS" \
    --set sidecar.dashboards.enabled=true \
    --set sidecar.dashboards.label=grafana_dashboard \
    --set sidecar.dashboards.labelValue="1" \
    --set sidecar.alerts.enabled=true \
    --set sidecar.alerts.label=grafana_alerts \
    --set sidecar.alerts.labelValue="1" \
    --set adminPassword=dojo-admin \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=128Mi \
    --timeout 3m \
    --wait
  echo "  ✓ Grafana installed. Default admin password: dojo-admin"
else
  echo "  Grafana release already present in '$NS' — skipping install."
fi

GRAFANA_POD=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=grafana \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

echo
echo "✓ Environment ready."
echo
echo "  Grafana pod: ${GRAFANA_POD:-<check kubectl -n $NS get pods>}"
echo "  Access UI:   kubectl -n $NS port-forward svc/grafana 3000:80"
echo "               then open http://localhost:3000  (admin / dojo-admin)"
echo
echo "  Your task: create TWO objects in namespace '$NS':"
echo "    1. A ConfigMap labeled grafana_dashboard=1 with valid dashboard JSON"
echo "       (must contain a \"panels\" array with at least one panel)."
echo "    2. A PrometheusRule (if prometheus-operator is installed) OR a"
echo "       ConfigMap labeled grafana_alerts=1 with Grafana alert rule YAML"
echo "       (must contain groups: and an alert: rule)."
echo
echo "  When done, run the verifier:"
echo "    bash courses/course-17-lgtm-operated/challenges/06-dashboards-and-alerts-as-code/verify.sh"
