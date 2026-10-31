#!/usr/bin/env bash
# Plants the "Guarantee It" scenario: a latency-sensitive 'cache' Deployment that
# ships as Burstable (cpu + memory REQUESTS only, no limits). The mission is to
# make requests == limits for both resources so pods land in Guaranteed QoS.
set -euo pipefail

NS=dojo-qos

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cache
  namespace: dojo-qos
  labels:
    app: cache
spec:
  replicas: 2
  selector:
    matchLabels:
      app: cache
  template:
    metadata:
      labels:
        app: cache
    spec:
      containers:
        - name: cache
          image: redis:7.2-alpine
          ports:
            - containerPort: 6379
          resources:
            # Requests only, no limits -> Burstable. This is the bug.
            requests:
              cpu: 100m
              memory: 64Mi
YAML

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Deployment 'cache' (redis:7.2-alpine) has cpu + memory REQUESTS but no limits,"
echo "  so every pod is Burstable — throttled and OOM-eligible under node pressure."
echo
echo "  Confirm the current class:"
echo "    kubectl -n $NS get pods -l app=cache -o jsonpath='{.items[*].status.qosClass}{\"\\n\"}'"
echo "    # -> Burstable Burstable"
echo
echo "  Mission: set requests == limits for BOTH cpu and memory on the 'cache'"
echo "  container so pods become Guaranteed, then run verify.sh."
