#!/usr/bin/env bash
# Plants the "Egress Lockdown" scenario: a namespace with pods that currently
# have unrestricted egress. No NetworkPolicies applied yet.
set -euo pipefail

NS=dojo-egress

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Plant a simple workload so the namespace has active pods to think about
cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: dojo-egress
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
          image: nicolaka/netshoot:v0.13
          command: ["sleep", "3600"]
          resources:
            requests:
              cpu: 20m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
YAML

echo
echo "✓ Namespace '$NS' created."
echo "  Deployment 'backend' (nicolaka/netshoot) planted — currently has unrestricted egress."
echo "  Author a default-deny-egress NetworkPolicy and an allow policy for DNS + monitoring, then run verify.sh."
