#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-mtls"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: $NAMESPACE
  annotations:
    dojo.mtls/status: "plaintext"
  labels:
    app: frontend
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
        image: nginx:1.27-alpine
        resources:
          limits:
            cpu: "100m"
            memory: "64Mi"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: $NAMESPACE
  annotations:
    dojo.mtls/status: "plaintext"
  labels:
    app: backend
spec:
  replicas: 1
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
        resources:
          limits:
            cpu: "100m"
            memory: "64Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
  namespace: $NAMESPACE
spec:
  selector:
    app: backend
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: interceptor
  namespace: $NAMESPACE
  labels:
    app: interceptor
    role: rogue
spec:
  containers:
  - name: interceptor
    image: alpine:3.20
    command: ["sh", "-c", "sleep 86400"]
    resources:
      limits:
        cpu: "50m"
        memory: "32Mi"
  restartPolicy: Always
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: intercept-proof
  namespace: $NAMESPACE
data:
  captured_at: "2024-01-15T02:34:00Z"
  captured_traffic: |
    GET /api/payments HTTP/1.1
    Host: backend-svc
    Authorization: Bearer eyJhbGciOiJSUzI1NiJ9...PLAINTEXT_TOKEN
    X-User-Id: user-4821

    HTTP/1.1 200 OK
    Content-Type: application/json

    {"account":"4111111111111111","balance":"$47,201.55","token":"prod-db-pass-aB3kM9"}
  note: "The interceptor read this from the network. Mutual TLS would have made this impossible — both sides must present certificates, encrypted end-to-end."
EOF

echo ""
echo "Setup complete. Namespace: $NAMESPACE"
echo "frontend and backend are deployed — currently communicating over plaintext HTTP."
echo "An interceptor pod is in the same namespace and can sniff traffic."
echo ""
echo "Enforce mTLS using Istio PeerAuthentication or another method."
echo "Then annotate both deployments and create the mtls-config ConfigMap."
