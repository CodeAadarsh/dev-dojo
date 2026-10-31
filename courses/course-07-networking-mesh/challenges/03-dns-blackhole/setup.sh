#!/usr/bin/env bash
# Plants the "DNS Blackhole" scenario: a Service with a selector/port mismatch.
set -euo pipefail

NS=dojo-dns

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "WARNING: current kube-context is not 'kind-dojo'. Targeting current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Deploy the backend pod — labelled version=v2, port 80
cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: dojo-dns
  labels:
    app: backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend
      version: v2
  template:
    metadata:
      labels:
        app: backend
        version: v2
    spec:
      containers:
        - name: backend
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

# Plant the broken Service — wrong version selector (v1) and wrong targetPort (8080)
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: api-svc
  namespace: dojo-dns
spec:
  selector:
    app: backend
    version: v1
  ports:
    - name: http
      port: 80
      targetPort: 8080
YAML

echo
echo "Scenario deployed to namespace '$NS'."
echo "  - Deployment 'backend' running nginx on port 80, labelled app=backend,version=v2"
echo "  - Service 'api-svc' has selector version=v1 and targetPort=8080 — BOTH are wrong"
echo ""
echo "  Confirm the break:"
echo "    kubectl -n $NS get endpoints api-svc"
echo "    # -> ENDPOINTS: <none>"
echo ""
echo "  Fix the Service's selector and targetPort, then run verify.sh."
