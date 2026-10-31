#!/usr/bin/env bash
# Plants the "Anti-Affinity Spread" scenario: a 3-replica StatefulSet with no
# anti-affinity rules, running in a cluster where all pods can land on one node.
set -euo pipefail

NS=dojo-spread

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

# Untaint the control-plane so all 3 nodes are schedulable.
# With only 2 workers and a hard anti-affinity rule, the 3rd replica would
# stay Pending. This mirrors what you'd do on a 3-node cluster in production.
CTRL_NODE=$(kubectl get nodes -l node-role.kubernetes.io/control-plane= -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$CTRL_NODE" ]; then
  kubectl taint nodes "$CTRL_NODE" node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
  echo "✓ Untainted control-plane node '$CTRL_NODE' — 3 schedulable nodes available."
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Plant a 3-replica StatefulSet WITHOUT anti-affinity (the broken state to fix).
cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: cache
  namespace: dojo-spread
  labels:
    app: cache
spec:
  serviceName: cache
  replicas: 3
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
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
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
  name: cache
  namespace: dojo-spread
spec:
  clusterIP: None
  selector:
    app: cache
  ports:
    - port: 80
YAML

echo
echo "✓ Namespace '$NS' ready."
echo "  StatefulSet 'cache' planted with 3 replicas and NO anti-affinity."
echo "  All 3 pods may land on the same node — that's the bug."
echo "  Check current placement: kubectl -n dojo-spread get pods -o wide"
echo "  Your mission: add podAntiAffinity to the StatefulSet so pods spread"
echo "  across multiple nodes, then run verify.sh."
