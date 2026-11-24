#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-docker-entrypoint"

echo "==> Setting up challenge 03-entrypoint-trap"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Broken deployment: command: ["/bin/sh"] with no args → exits instantly
kubectl apply -f - << 'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: dojo-docker-entrypoint
  labels:
    app: web
  annotations:
    dojo.docker/bug: "command overrides ENTRYPOINT but args are empty — shell exits immediately"
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
          command: ["/bin/sh"]
          args: []
YAML

kubectl create configmap entrypoint-hint \
  --from-literal=hint="The container spec has 'command' set. In Kubernetes, 'command' overrides ENTRYPOINT and 'args' overrides CMD. What happens when you run /bin/sh with no arguments?" \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "✓ Namespace: $NAMESPACE"
echo "✓ Deployment: web (broken — exits immediately with code 0)"
echo ""
echo "Check the symptoms:"
echo "  kubectl get pods -n $NAMESPACE"
echo "  kubectl describe pod -n $NAMESPACE -l app=web"
