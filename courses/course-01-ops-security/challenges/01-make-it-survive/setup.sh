#!/usr/bin/env bash
# Plants the "Make It Survive" scenario: a deliberately fragile Deployment.
set -euo pipefail

NS=dojo-resilient

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: dojo-resilient
  labels:
    app: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
YAML

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  A fragile single-replica Deployment 'web': no probes, no PDB, no resource requests."
echo "  Fix it to the target state in the brief, then run verify.sh."
