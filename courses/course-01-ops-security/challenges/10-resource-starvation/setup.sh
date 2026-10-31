#!/usr/bin/env bash
# Plants the "Resource Starvation" scenario: a BestEffort workload with NO
# resource requests or limits, and NO LimitRange guarding the namespace.
set -euo pipefail

NS=dojo-resources

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: dojo-resources
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
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
YAML

echo
echo "⏳ Waiting for the api pods to schedule..."
kubectl -n "$NS" rollout status deploy/api --timeout=90s || \
  echo "   (rollout not Ready yet — check 'kubectl -n $NS get pods' before verifying)"

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Planted: Deployment 'api' — 2 replicas, nginx:1.27-alpine, NO requests/limits (BestEffort)."
echo "  Missing: NO LimitRange, so any pod forgetting requests/limits here is BestEffort by default."
echo
echo "  Inspect the damage:"
echo "    kubectl -n $NS get pod -l app=api -o jsonpath='{.items[0].status.qosClass}{\"\\n\"}'"
echo
echo "  Your move: add CPU+memory requests AND limits to the 'api' container,"
echo "  create a LimitRange with default request/limit in '$NS', then run verify.sh."
