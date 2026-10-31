#!/usr/bin/env bash
# Plants the "Pin the Pod" scenario: a worker node labelled tier=gold and a
# Deployment with NO placement rules, so its pods scatter across workers.
set -euo pipefail

NS=dojo-sched

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Pick the first schedulable worker (anything that isn't the control-plane) and
# make it the "gold" node. Idempotent: --overwrite re-labels on re-run.
WORKER=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
  | grep -v control-plane | head -n1)

if [ -z "$WORKER" ]; then
  echo "✗ Could not find a worker node. Is the 'dojo' cluster up with workers?" >&2
  exit 1
fi

kubectl label node "$WORKER" tier=gold --overwrite

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pinme
  namespace: dojo-sched
  labels:
    app: pinme
spec:
  replicas: 3
  selector:
    matchLabels:
      app: pinme
  template:
    metadata:
      labels:
        app: pinme
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 25m
              memory: 16Mi
YAML

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Gold node     : $WORKER   (labelled tier=gold)"
echo "  Deployment    : pinme (3x nginx:1.27-alpine, NO affinity — pods scatter)"
echo "  Current spread:"
kubectl -n "$NS" get pods -o wide --no-headers 2>/dev/null | awk '{printf "    %-28s %s\n", $1, $7}'
echo
echo "  Pin 'pinme' to the gold node with required nodeAffinity, roll the pods,"
echo "  then run verify.sh."
