#!/usr/bin/env bash
# Plants the "Zero-Downtime Rollout" scenario: a Deployment on DEFAULT rollout
# settings with NO readinessProbe and NO minReadySeconds — every deploy briefly
# drops capacity and routes traffic to cold pods.
set -euo pipefail

NS=dojo-rollout

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
  namespace: dojo-rollout
  labels:
    app: web
spec:
  replicas: 3
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
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 64Mi
YAML

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Deployment 'web' (nginx:1.27-alpine, 3 replicas) is on DEFAULT rollout settings:"
echo "    - no explicit strategy (maxUnavailable/maxSurge default to 25%)"
echo "    - no readinessProbe (pods count 'Ready' the instant the process starts)"
echo "    - minReadySeconds: 0 (no soak time before the rollout advances)"
echo
echo "  Fix it to the target state in the brief:"
echo "    maxUnavailable: 0 + maxSurge: 1, a readinessProbe, and minReadySeconds >= 5."
echo "  Then run verify.sh."
