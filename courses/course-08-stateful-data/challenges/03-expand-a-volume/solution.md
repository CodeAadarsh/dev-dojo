# Solution — Expand a Volume

One command expands the PVC:

```bash
kubectl patch pvc dojo-data -n dojo-resize \
  -p '{"spec":{"resources":{"requests":{"storage":"3Gi"}}}}'
```

Or interactively:

```bash
kubectl edit pvc dojo-data -n dojo-resize
# Find the line:  storage: 1Gi
# Change it to:   storage: 3Gi
# Save and exit (:wq)
```

Verify the spec was accepted:

```bash
kubectl get pvc dojo-data -n dojo-resize \
  -o jsonpath='{.spec.resources.requests.storage}{"\n"}'
# 3Gi

kubectl describe pvc dojo-data -n dojo-resize | grep -A5 Conditions
```

Then run the verifier:

```bash
bash courses/course-08-stateful-data/challenges/03-expand-a-volume/verify.sh
```

## Why this works — and why it sometimes doesn't

When you patch the PVC spec, the API server accepts the change only if the StorageClass has `allowVolumeExpansion: true`. The `dojo-expandable` class was created with that flag. Without it, the API rejects the patch:

```
The PersistentVolumeClaim "dojo-data" is invalid:
spec.resources.requests.storage: Forbidden: field is immutable
```

After the spec is accepted, a two-phase resize happens on real cloud backends:

1. **Block device expansion** — the CSI controller plugin calls `ControllerExpandVolume`. The backing disk (EBS volume, GCP persistent disk) is enlarged. The PV `status.capacity.storage` updates to reflect the new size.
2. **Filesystem expansion** — the kubelet's CSI node plugin calls `NodeExpandVolume` and runs `resize2fs` (ext4) or `xfs_growfs` (xfs) inside the pod. The `FileSystemResizePending` condition clears and becomes `Resizing` → gone.

In kind, step 1 is a no-op (local-path doesn't implement `ControllerExpandVolume`), so the `status.capacity.storage` stays at the original size and `FileSystemResizePending` may appear. The API still accepted the spec change, which is the mechanic this challenge teaches.

```bash
# On a real cluster you'd watch this progression:
kubectl get pvc dojo-data -n dojo-resize -w
# NAME        STATUS   VOLUME         CAPACITY   ACCESS MODES  ...
# dojo-data   Bound    pvc-abc123     1Gi        RWO           ...
# dojo-data   Bound    pvc-abc123     3Gi        RWO           ...   <- after block expansion
```

## Key constraint: no shrinking

You can only expand — never shrink. The API rejects any patch that decreases `spec.resources.requests.storage`:

```bash
kubectl patch pvc dojo-data -n dojo-resize \
  -p '{"spec":{"resources":{"requests":{"storage":"500Mi"}}}}'
# Error: spec.resources.requests.storage: Forbidden: field is immutable
```

If you genuinely need a smaller volume: snapshot the data, delete the PVC (and wait for the PV to be reclaimed), create a new smaller PVC, restore data. That's an outage. Size right from the start, or provision large and expect to expand.

## Find expandable StorageClasses in any cluster

```bash
kubectl get sc \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.allowVolumeExpansion}{"\n"}{end}'
# standard            false
# dojo-expandable     true
```

On EKS: `gp3` and `gp2` CSI classes typically have `allowVolumeExpansion: true`. On GKE: `standard-rwo`, `premium-rwo`. On AKS: `managed-csi` and `managed-csi-premium`. On a bare-metal cluster: whatever the storage admin set up — check before you need to expand at 3am.
