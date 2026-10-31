#!/usr/bin/env bash
# Plants the "Default Deny Then Allow" scenario: backend + client in dojo-np, no policies.
set -euo pipefail

NS=dojo-np

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "WARNING: current kube-context is not 'kind-dojo'. Targeting current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: dojo-np
  labels:
    app: backend
spec:
  replicas: 1
  selector:
    matchLabels:
      role: backend
  template:
    metadata:
      labels:
        app: backend
        role: backend
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
---
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
  namespace: dojo-np
spec:
  selector:
    role: backend
  ports:
    - name: http
      port: 80
      targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client
  namespace: dojo-np
  labels:
    app: client
spec:
  replicas: 1
  selector:
    matchLabels:
      role: client
  template:
    metadata:
      labels:
        app: client
        role: client
    spec:
      containers:
        - name: client
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
          resources:
            requests:
              cpu: 25m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 32Mi
YAML

echo
echo "Scenario deployed to namespace '$NS'."
echo "  - Deployment 'backend' (label role=backend) + Service 'backend-svc' on port 80"
echo "  - Deployment 'client'  (label role=client)  — currently has free access to backend"
echo ""
echo "  Before applying policies, confirm the flat network:"
echo "    CLIENT=\$(kubectl -n $NS get pod -l role=client -o jsonpath='{.items[0].metadata.name}')"
echo "    kubectl -n $NS exec \$CLIENT -- wget -qO- http://backend-svc"
echo ""
echo "  Then create a default-deny-ingress NetworkPolicy and an allow-frontend-to-backend policy."
echo "  Run verify.sh when both policies exist."
