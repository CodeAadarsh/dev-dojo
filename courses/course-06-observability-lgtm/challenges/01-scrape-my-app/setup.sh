#!/usr/bin/env bash
# Plants the "Scrape My App" scenario: a metrics-emitting Deployment with no
# Service and no ServiceMonitor. The learner must add both.
set -euo pipefail

NS=dojo-obs

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: example-metrics-app
  namespace: dojo-obs
  labels:
    app: example-metrics-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: example-metrics-app
  template:
    metadata:
      labels:
        app: example-metrics-app
    spec:
      containers:
        - name: app
          image: quay.io/brancz/prometheus-example-app:v0.5.0
          ports:
            - containerPort: 8080
              name: metrics
YAML

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Deployment 'example-metrics-app' is running — /metrics is live on port 8080."
echo "  No Service and no ServiceMonitor exist yet."
echo "  Create them so Prometheus can scrape this app, then run verify.sh."
