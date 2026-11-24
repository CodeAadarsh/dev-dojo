#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-docker-cgroup"

echo "==> Setting up challenge 07-cgroup-enforcer"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - << 'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hog
  namespace: dojo-docker-cgroup
  labels:
    app: hog
  annotations:
    dojo.docker/has-limits: "false"
    dojo.docker/problem: "no resource requests or limits — BestEffort QoS, noisy neighbor risk"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hog
  template:
    metadata:
      labels:
        app: hog
    spec:
      containers:
        - name: hog
          image: nginx:1.27-alpine
YAML

echo ""
echo "✓ Namespace: $NAMESPACE"
echo "✓ Deployment: hog (no resource limits)"
echo ""
echo "Check the current state:"
echo "  kubectl get deployment hog -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[0].resources}'"
echo ""
echo "Add cpu: 100m and memory: 128Mi to both requests and limits."
