#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-docker-network"

echo "==> Setting up challenge 08-network-detective"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - << 'YAML'
# Backend deployment — pods are labeled app=backend
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: dojo-docker-network
  labels:
    app: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
        - name: backend
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
---
# Service with WRONG selector — app=backend-wrong instead of app=backend
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
  namespace: dojo-docker-network
  annotations:
    dojo.docker/bug: "selector points to app=backend-wrong — no pods match"
spec:
  selector:
    app: backend-wrong
  ports:
    - port: 80
      targetPort: 80
---
# Frontend pod that tries to reach the backend
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: dojo-docker-network
  labels:
    app: frontend
  annotations:
    dojo.docker/can-reach-backend: "false"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: frontend
          image: curlimages/curl:8.10.1
          command: ["sleep", "3600"]
YAML

echo ""
echo "✓ Namespace: $NAMESPACE"
echo "✓ Deployment: backend (2 replicas, label app=backend)"
echo "✓ Service: backend-svc (broken selector: app=backend-wrong)"
echo "✓ Deployment: frontend"
echo ""
echo "Diagnose:"
echo "  kubectl get endpoints backend-svc -n $NAMESPACE"
echo "  kubectl get pods -n $NAMESPACE --show-labels"
