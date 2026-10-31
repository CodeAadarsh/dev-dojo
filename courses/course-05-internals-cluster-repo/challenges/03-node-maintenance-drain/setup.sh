#!/usr/bin/env bash
# Plants the "Drain Without Downtime" scenario: a 3-replica Deployment spread
# across the worker nodes, protected by a PodDisruptionBudget (minAvailable: 2).
set -euo pipefail

NS=dojo-maint

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
  namespace: dojo-maint
  labels:
    app: maint
spec:
  replicas: 3
  selector:
    matchLabels:
      app: maint
  template:
    metadata:
      labels:
        app: maint
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: maint
      containers:
        - name: web
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
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
  namespace: dojo-maint
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: maint
YAML

echo
echo "Waiting for the Deployment to become available across the workers…"
kubectl -n "$NS" rollout status deploy/web --timeout=90s || true

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Deployment 'web' (3 replicas, label app=maint) spread across worker nodes,"
echo "  protected by PodDisruptionBudget 'web-pdb' (minAvailable: 2)."
echo
echo "  See where the pods landed:"
echo "    kubectl -n $NS get pods -o wide"
echo
echo "  Mission: cordon one worker that holds 'web' pods, then drain it (respecting"
echo "  the PDB). When the app is still healthy on the other worker, run verify.sh."
