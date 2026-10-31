#!/usr/bin/env bash
# Plants the "Who Gets Evicted First" scenario: a critical 'payments' Deployment
# running at the DEFAULT priority (0), indistinguishable from any batch workload,
# plus a low-priority 'batch' tenant to make the ranking story concrete. No
# PriorityClass is assigned yet — that's the mission.
set -euo pipefail

NS=dojo-priority

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
  namespace: dojo-priority
  labels:
    app: payments
    tier: critical
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payments
  template:
    metadata:
      labels:
        app: payments
        tier: critical
    spec:
      # priorityClassName intentionally absent -> effective priority 0.
      containers:
        - name: payments
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 150m
              memory: 64Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: batch
  namespace: dojo-priority
  labels:
    app: batch
    tier: best-effort
spec:
  replicas: 2
  selector:
    matchLabels:
      app: batch
  template:
    metadata:
      labels:
        app: batch
        tier: best-effort
    spec:
      containers:
        - name: batch
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 150m
              memory: 64Mi
YAML

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Deployment 'payments' (critical revenue path) runs at priority 0 — the SAME"
echo "  effective priority as the throwaway 'batch' tenant beside it. When a node fills"
echo "  up, the scheduler and kubelet can't tell them apart."
echo
echo "  Mission: create your own high-value PriorityClass (value >= 100000, NOT a"
echo "  system-* class) and set spec.template.spec.priorityClassName on 'payments'."
echo "  Then run verify.sh."
echo
echo "  Note: this lab verifies the priority WIRING, so you don't need to force real"
echo "        node pressure to earn the flag. See solution.md to watch preemption live."
