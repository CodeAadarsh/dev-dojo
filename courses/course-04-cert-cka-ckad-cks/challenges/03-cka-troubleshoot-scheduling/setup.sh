#!/usr/bin/env bash
# "Why Won't It Schedule" — deploys a workload pinned to a node label that no
# node has, so it sits Pending. The learner diagnoses + fixes.
set -euo pipefail

NS=dojo-sched-fix
if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  current kube-context is not 'kind-dojo' — targeting current context anyway."
fi
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reports
  namespace: dojo-sched-fix
  labels: { app: reports }
spec:
  replicas: 2
  selector:
    matchLabels: { app: reports }
  template:
    metadata:
      labels: { app: reports }
    spec:
      nodeSelector:
        disktype: ssd          # no node in the dojo cluster has this label -> Pending
      containers:
        - name: app
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
YAML

echo
echo "✓ Deployed 'reports' to '$NS' — its pods are stuck Pending."
echo "  Diagnose with: kubectl -n $NS describe pod <pod>   (read the Events)"
echo "  Fix it minimally, then run verify.sh."
