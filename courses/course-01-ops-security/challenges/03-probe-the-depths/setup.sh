#!/usr/bin/env bash
# Plants the "Probe the Depths" scenario: a Deployment with NO probes.
set -euo pipefail

NS=dojo-probes

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
  namespace: dojo-probes
  labels:
    app: web
spec:
  replicas: 2
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
echo "  Deployment 'web' (2 replicas, nginx:1.27-alpine) has NO readinessProbe and NO livenessProbe."
echo "  Add both probes (httpGet / on port 80) without crashlooping the pods, then run verify.sh:"
echo "    bash courses/course-01-ops-security/challenges/03-probe-the-depths/verify.sh"
