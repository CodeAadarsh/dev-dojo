#!/usr/bin/env bash
# Plants the "State That Survives" scenario into dojo-storage: a Deployment
# 'notes' that writes to /data on an emptyDir volume, so all data is lost on
# every pod restart / reschedule.
set -euo pipefail

NS=dojo-storage

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notes
  namespace: dojo-storage
  labels:
    app: notes
spec:
  replicas: 1
  selector:
    matchLabels:
      app: notes
  template:
    metadata:
      labels:
        app: notes
    spec:
      containers:
        - name: notes
          image: busybox:1.36
          command:
            - sh
            - -c
            - 'echo "$(date -u) booted on $(hostname)" >> /data/notes.log; echo "=== /data/notes.log ==="; cat /data/notes.log; sleep 3600'
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          emptyDir: {}
YAML

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Planted: Deployment 'notes' (busybox:1.36) appending to /data/notes.log on an emptyDir."
echo "  Prove the data loss:"
echo "    kubectl -n $NS exec deploy/notes -- cat /data/notes.log   # one boot line"
echo "    kubectl -n $NS delete pod -l app=notes                    # restart"
echo "    kubectl -n $NS exec deploy/notes -- cat /data/notes.log   # history gone"
echo "  Convert it to a StatefulSet with volumeClaimTemplates (see brief), then run verify.sh."
