#!/usr/bin/env bash
# Plants the "Gateway API Route" scenario: a Service waiting for a Gateway + HTTPRoute.
set -euo pipefail

NS=dojo-gw

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "WARNING: current kube-context is not 'kind-dojo'. Targeting current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

# Ensure Gateway API CRDs exist before proceeding
if ! kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1; then
  echo "ERROR: Gateway API CRDs not found."
  echo "  Install them first:"
  echo "    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml"
  exit 1
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: dojo-gw
  labels:
    app: web
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
---
apiVersion: v1
kind: Service
metadata:
  name: web-svc
  namespace: dojo-gw
spec:
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: 80
YAML

echo
echo "Scenario deployed to namespace '$NS'."
echo "  Deployment 'web' + Service 'web-svc' are running."
echo "  Your task: create a Gateway 'dojo-gw' and an HTTPRoute 'web-route' that routes to web-svc:80."
echo "  Run verify.sh once both objects exist."
