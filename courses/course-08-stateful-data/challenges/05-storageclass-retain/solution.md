# Solution — StorageClass: Retain Your Data

Two manifests: the custom StorageClass, and a PVC that binds to it.

```yaml
# dojo-retain-sc.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: dojo-retain
provisioner: rancher.io/local-path      # kind's dynamic provisioner
reclaimPolicy: Retain                   # PV survives PVC deletion
allowVolumeExpansion: true              # resize without recreate
volumeBindingMode: WaitForFirstConsumer # don't provision until a pod claims it
---
# dojo-retain-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: retained-data
  namespace: dojo-sc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: dojo-retain         # must match the StorageClass name above
  resources:
    requests:
      storage: 500Mi
```

Apply and verify:

```bash
kubectl apply -f dojo-retain-sc.yaml
kubectl apply -f dojo-retain-pvc.yaml
# WaitForFirstConsumer means the PVC stays Pending until a pod binds it.
# Create a quick pod to trigger provisioning:
kubectl run -n dojo-sc trigger --image=busybox:1.36 \
  --restart=Never \
  --overrides='{"spec":{"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"retained-data"}}],"containers":[{"name":"trigger","image":"busybox:1.36","command":["sh","-c","echo bound && sleep 2"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}]}}' \
  --rm -it
kubectl -n dojo-sc get pvc retained-data
# -> phase: Bound
bash courses/course-08-stateful-data/challenges/05-storageclass-retain/verify.sh
```

If you use `volumeBindingMode: Immediate` instead, the PVC binds without a pod.

## Why each piece matters

**`reclaimPolicy: Retain` is the only safe choice for stateful workloads.** With `Delete`, the instant someone (an operator, a CI script, a tired engineer at 2am) deletes the PVC, the cloud disk is gone — no tombstone, no recycle bin. With `Retain`, the PV moves to `Released` state: still bound to the old PVC's UID but with the data intact. You can manually create a new PVC that references that specific PV by name and regain access to the data.

**`volumeBindingMode: WaitForFirstConsumer`.** Immediate binding picks any node. For `local-path` provisioner (which backs the volume with a host directory on a specific node), that means your pod must always schedule to *that* node or it gets stuck with a `VolumeNodeAffinity conflict` error. `WaitForFirstConsumer` defers the binding until a pod is scheduled, so the PV ends up on the same node as the pod. This is the correct mode for node-local provisioners.

**`allowVolumeExpansion: true`.** Resizing a PVC is a two-step process: (1) edit `spec.resources.requests.storage` upward, (2) the provisioner detects the delta and requests an underlying disk resize. The pod must be restarted to trigger the filesystem resize in-node. If the StorageClass doesn't have `allowVolumeExpansion: true`, the API rejects the edit entirely.

## What Retain looks like in practice

```bash
# Prove the PV survives PVC deletion:
PV=$(kubectl -n dojo-sc get pvc retained-data -o jsonpath='{.spec.volumeName}')
kubectl delete pvc -n dojo-sc retained-data
kubectl get pv "$PV"
# -> STATUS: Released   RECLAIM POLICY: Retain  (not Terminating, not gone)
```

A PV in `Released` still has its `claimRef` pointing at the deleted PVC. To re-bind it:

```bash
kubectl patch pv "$PV" -p '{"spec":{"claimRef":null}}'
# Now the PV is Available — create a new PVC with storageClassName: dojo-retain and it will bind.
```
