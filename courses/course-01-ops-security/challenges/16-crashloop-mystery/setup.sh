#!/usr/bin/env bash
# Plants "The CrashLoop Mystery": a Deployment whose container fails fast on
# startup because a required env var is missing, so it CrashLoopBackOffs.
set -euo pipefail

NS=dojo-crash

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# The container is a fail-fast "app": it refuses to start without DATABASE_URL.
# The planted Deployment never sets DATABASE_URL, so the process exits 1 on every
# start and the kubelet restarts it with exponential backoff -> CrashLoopBackOff.
cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: dojo-crash
  labels:
    app: api
spec:
  replicas: 2
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
          image: busybox:1.36
          command: ["/bin/sh", "-c"]
          args:
            - |
              if [ -z "${DATABASE_URL:-}" ]; then
                echo "FATAL: DATABASE_URL is required but was not set; refusing to start" >&2
                exit 1
              fi
              echo "api: connected to ${DATABASE_URL}, serving on :8080"
              exec sleep infinity
          resources:
            requests:
              cpu: 25m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 32Mi
YAML

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Deployment 'api' is CrashLoopBackOff-ing. Something it needs on startup is missing."
echo "  Diagnose with:  kubectl -n $NS describe pod   |  kubectl -n $NS logs --previous   |  kubectl -n $NS get events --sort-by=.lastTimestamp"
echo "  Fix it so pods run clean, then run verify.sh."
