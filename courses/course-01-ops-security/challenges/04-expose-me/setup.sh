#!/usr/bin/env bash
# Plants the "Expose Me" scenario: a running Deployment with NO Service.
set -euo pipefail

NS=dojo-expose

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
  namespace: dojo-expose
  labels:
    app: shop
spec:
  replicas: 3
  selector:
    matchLabels:
      app: shop
  template:
    metadata:
      labels:
        app: shop
    spec:
      containers:
        - name: shop
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
              cpu: 25m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
YAML

echo
echo "⏳ Waiting for the shop pods to become Ready..."
kubectl -n "$NS" rollout status deploy/shop --timeout=90s || \
  echo "   (rollout not Ready yet — check 'kubectl -n $NS get pods' before verifying)"

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Planted: Deployment 'shop' — 3 replicas, nginx:1.27-alpine, label app=shop, on port 80."
echo "  Missing: NO Service exists, so nothing can route to these pods."
echo
echo "  Your move: create a ClusterIP Service selecting app=shop on port 80, then run verify.sh."
