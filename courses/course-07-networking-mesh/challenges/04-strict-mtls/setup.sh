#!/usr/bin/env bash
# Plants the "Strict mTLS" scenario: namespace with Istio injection enabled and
# a test workload running in PERMISSIVE mode (Istio mesh default).
set -euo pipefail

NS=dojo-mtls

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

if ! kubectl get crd peerauthentications.security.istio.io >/dev/null 2>&1; then
  echo "⚠  Istio CRDs not found. Install Istio before running this setup:"
  echo "   curl -L https://istio.io/downloadIstio | sh -"
  echo "   istioctl install --set profile=demo -y"
  echo "   Continuing anyway — kubectl apply for the app will fail without the CRDs."
fi

# Create namespace with Istio sidecar injection enabled
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" istio-injection=enabled --overwrite

# Deploy a simple echo server as a test workload
cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: dojo-mtls
  labels:
    app: echo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: echo
  template:
    metadata:
      labels:
        app: echo
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:1.0.0
          args:
            - "-text=dojo-mtls-echo"
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
  name: echo
  namespace: dojo-mtls
spec:
  selector:
    app: echo
  ports:
    - port: 80
      targetPort: 5678
YAML

echo
echo "✓ Namespace '$NS' created with label istio-injection=enabled."
echo "  Deployment 'echo' planted (gets Istio sidecar on next rollout if injection is active)."
echo "  The namespace currently uses Istio's mesh-wide default (PERMISSIVE)."
echo "  Author a PeerAuthentication with mtls.mode=STRICT to lock it down, then run verify.sh."
