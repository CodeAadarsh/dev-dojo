#!/usr/bin/env bash
# Plants the "Chaos Mesh Experiment" scenario: target app in dojo-chaos.
# Chaos Mesh itself must be pre-installed — see brief.md for the Helm command.
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
    challenge: chaos-mesh
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
echo "✓ Target Deployment 'web' (3 replicas) planted in namespace '$NS'."
echo
echo "IMPORTANT: Chaos Mesh must be installed before applying chaos CRs."
echo "  See brief.md for the Helm install command."
echo
echo "Next steps:"
echo "  1. Install Chaos Mesh (if not done): helm install chaos-mesh ..."
echo "  2. Author a PodChaos or NetworkChaos CR targeting '$NS'"
echo "  3. Apply it:      kubectl apply -f chaos-experiment.yaml"
echo "  4. Run verifier:  bash courses/course-28-chaos-engineering/challenges/03-chaos-mesh-experiment/verify.sh"
