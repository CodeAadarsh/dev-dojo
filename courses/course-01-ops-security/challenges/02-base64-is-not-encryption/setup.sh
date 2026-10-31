#!/usr/bin/env bash
# Plants the "base64 Is Not Encryption" scenario: a Secret holding a flag,
# mounted into a running workload as environment variables.
set -euo pipefail

NS=dojo-leaky

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create secret generic app-config \
  --from-literal=DB_HOST=postgres.dojo-leaky.svc \
  --from-literal=DB_USER=billing \
  --from-literal=FLAG='KUBE{base64_is_not_encryption}' \
  --dry-run=client -o yaml | kubectl apply -f -

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: billing
  namespace: dojo-leaky
  labels:
    app: billing
spec:
  replicas: 1
  selector:
    matchLabels:
      app: billing
  template:
    metadata:
      labels:
        app: billing
    spec:
      containers:
        - name: app
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
          envFrom:
            - secretRef:
                name: app-config
YAML

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  A Secret 'app-config' holds a flag; the 'billing' Deployment mounts it as env."
echo "  Extract the flag and submit it in the platform."
