#!/usr/bin/env bash
# "Harden the Pod" — deploys an UNHARDENED workload; the learner hardens it.
set -euo pipefail

NS=dojo-cks
if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  current kube-context is not 'kind-dojo' — targeting current context anyway."
fi
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-app
  namespace: dojo-cks
  labels: { app: secure-app }
spec:
  replicas: 1
  selector:
    matchLabels: { app: secure-app }
  template:
    metadata:
      labels: { app: secure-app }
    spec:
      containers:
        - name: app
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
          # no securityContext yet — wide open. Harden it.
YAML

echo
echo "✓ Deployed unhardened 'secure-app' to '$NS'."
echo "  Add the CKS securityContext hardening (see brief), keep it Running, then run verify.sh."
