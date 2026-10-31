#!/usr/bin/env bash
# Plants "No Endpoints, No Service": a healthy Deployment (app=api) fronted by a
# Service whose selector (app=apiv1) matches nothing, so it has zero endpoints.
set -euo pipefail

NS=dojo-endpoints

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Healthy backend pods, labelled app=api, serving HTTP on :80.
cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: dojo-endpoints
  labels:
    app: api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: nginx:1.27-alpine
          ports:
            - name: http
              containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            requests:
              cpu: 25m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 32Mi
---
# The bug: selector says app=apiv1, but the pods are labelled app=api.
# A Service with a selector that matches no pods gets ZERO endpoints and
# silently blackholes every connection.
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: dojo-endpoints
spec:
  type: ClusterIP
  selector:
    app: apiv1
  ports:
    - name: http
      port: 80
      targetPort: 80
YAML

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Deployment 'api' (3 healthy pods) + Service 'api' that refuses all traffic."
echo "  Diagnose with:  kubectl -n $NS get endpoints api   |   kubectl -n $NS describe svc api   |   kubectl -n $NS get pods --show-labels"
echo "  Make the Service actually back the pods, then run verify.sh."
