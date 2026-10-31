#!/usr/bin/env bash
# Plants the "Budget for Disruption" scenario: a 3-replica Deployment 'api' with
# NO PodDisruptionBudget — a node drain can evict all pods at once.
set -euo pipefail

NS=dojo-pdb

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: dojo-pdb
  labels:
    app: api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
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
echo "  Deployment 'api' (nginx:1.27-alpine, 3 replicas, label app=api) has NO PDB."
echo "  A 'kubectl drain' could evict all 3 pods at once during a node upgrade."
echo
echo "  Create a policy/v1 PodDisruptionBudget with minAvailable: 2 selecting app=api,"
echo "  then run verify.sh."
