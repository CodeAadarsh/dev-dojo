#!/usr/bin/env bash
# Plants the "Kill and Heal" scenario: a healthy 3-replica Deployment to destroy and watch self-heal.
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
    challenge: kill-and-heal
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
echo "✓ Deployment 'web' (3 replicas, nginx:1.27-alpine) planted in namespace '$NS'."
echo
echo "Next steps:"
echo "  1. Wait for pods:  kubectl -n $NS get pods"
echo "  2. Delete a pod:   kubectl -n $NS delete pod <name>"
echo "  3. Watch healing:  kubectl -n $NS get pods -w"
echo "  4. Run verifier:   bash courses/course-28-chaos-engineering/challenges/01-kill-and-heal/verify.sh"
