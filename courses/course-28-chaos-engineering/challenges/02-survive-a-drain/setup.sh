#!/usr/bin/env bash
# Plants the "Survive a Drain" scenario: 3-replica Deployment with soft pod anti-affinity.
set -euo pipefail

NS=dojo-chaos

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
  namespace: dojo-chaos
  labels:
    app: web
    challenge: survive-drain
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
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: web
                topologyKey: kubernetes.io/hostname
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
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 64Mi
YAML

echo
echo "✓ Deployment 'web' (3 replicas, soft anti-affinity) planted in namespace '$NS'."
echo
echo "Next steps (read brief.md first):"
echo "  1. Add a PDB protecting 'web' (minAvailable: 2)"
echo "  2. Find worker nodes: kubectl get nodes"
echo "  3. Drain one worker:  kubectl drain <worker> --ignore-daemonsets --delete-emptydir-data"
echo "  4. Run verifier:      bash courses/course-28-chaos-engineering/challenges/02-survive-a-drain/verify.sh"
