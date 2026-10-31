#!/usr/bin/env bash
# Plants the "Expand a Volume" scenario: creates namespace dojo-resize,
# an expandable StorageClass, a 1Gi PVC, and a workload to bind the PVC.
# Re-running is safe — all objects use apply.
set -euo pipefail

NS=dojo-resize

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# StorageClass with allowVolumeExpansion: true.
# kind's built-in 'standard' class has allowVolumeExpansion: false, so we
# create a separate class backed by the same provisioner.
cat <<'YAML' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: dojo-expandable
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
YAML

# 1Gi PVC using the expandable class
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dojo-data
  namespace: dojo-resize
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: dojo-expandable
  resources:
    requests:
      storage: 1Gi
YAML

# A long-lived pod to ensure the PVC binds (local-path provisions on first use)
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: dojo-data-writer
  namespace: dojo-resize
spec:
  restartPolicy: Always
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "while true; do sleep 3600; done"]
      volumeMounts:
        - name: data
          mountPath: /data
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: dojo-data
YAML

echo
echo "✓ Namespace '$NS', StorageClass 'dojo-expandable', PVC 'dojo-data' (1Gi), pod 'dojo-data-writer' applied."
echo
echo "  Wait for the PVC to become Bound:"
echo "      kubectl get pvc dojo-data -n $NS -w"
echo
echo "  Then expand it to >= 2Gi and run verify.sh."
