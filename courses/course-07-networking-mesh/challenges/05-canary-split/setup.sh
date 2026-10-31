#!/usr/bin/env bash
# Plants the "Canary Traffic Split" scenario: two app versions behind one Service.
set -euo pipefail

NS=dojo-canary

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

if ! kubectl get crd virtualservices.networking.istio.io >/dev/null 2>&1; then
  echo "⚠  Istio CRDs not found. Install Istio before running this setup:"
  echo "   curl -L https://istio.io/downloadIstio | sh -"
  echo "   istioctl install --set profile=demo -y"
  echo "   Continuing — the workloads will deploy but Istio objects will fail without CRDs."
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" istio-injection=enabled --overwrite

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-v1
  namespace: dojo-canary
  labels:
    app: myapp
    version: v1
spec:
  replicas: 2
  selector:
    matchLabels:
      app: myapp
      version: v1
  template:
    metadata:
      labels:
        app: myapp
        version: v1
    spec:
      containers:
        - name: app
          image: hashicorp/http-echo:1.0.0
          args:
            - "-text=v1-response"
          ports:
            - containerPort: 5678
          resources:
            requests:
              cpu: 20m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 32Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-v2
  namespace: dojo-canary
  labels:
    app: myapp
    version: v2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: myapp
      version: v2
  template:
    metadata:
      labels:
        app: myapp
        version: v2
    spec:
      containers:
        - name: app
          image: hashicorp/http-echo:1.0.0
          args:
            - "-text=v2-response"
          ports:
            - containerPort: 5678
          resources:
            requests:
              cpu: 20m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 32Mi
---
apiVersion: v1
kind: Service
metadata:
  name: app
  namespace: dojo-canary
spec:
  selector:
    app: myapp
  ports:
    - port: 80
      targetPort: 5678
YAML

echo
echo "✓ Namespace '$NS' created with label istio-injection=enabled."
echo "  Deployment 'app-v1' (2 replicas, label version=v1) and 'app-v2' (1 replica, label version=v2) deployed."
echo "  Service 'app' selects all pods with app=myapp (plain round-robin for now)."
echo "  Author a VirtualService + DestinationRule to shift traffic 90/10, then run verify.sh."
