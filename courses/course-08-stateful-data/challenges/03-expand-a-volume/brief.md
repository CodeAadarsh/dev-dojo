# Expand a Volume

Your team's Postgres instance is hitting disk pressure warnings. The PVC is at 90% capacity. On your cloud cluster you'd patch the PVC spec, wait for the CSI driver to expand the block device, and optionally restart the pod to trigger a filesystem resize — no data loss, no downtime. This challenge teaches you exactly that API.

The setup script has already planted a 1Gi PVC named `dojo-data` in namespace `dojo-resize`, backed by an expandable StorageClass (`dojo-expandable`). Your job is to expand it to at least 2Gi.

## Target state

Namespace: `dojo-resize`. The verifier accepts your solution when:

1. **`spec.resources.requests.storage` on PVC `dojo-data` is ≥ 2Gi** — the request must be expressed in `Gi` units (e.g. `2Gi`, `3Gi`).

The verifier also reports the current `status.capacity.storage` and any resize conditions for your information.

> **Kind limitation.** The `rancher.io/local-path` provisioner that backs `dojo-expandable` does not perform filesystem-level expansion — so `status.capacity.storage` will likely stay at `1Gi` and you may see a `FileSystemResizePending` condition. On a real cloud cluster with an EBS or GCP-PD CSI driver, the block device expands and the kubelet resizes the filesystem. The API mechanics are identical — patching the PVC spec is what triggers the whole chain. That's what this challenge exercises.

## The expansion API

Expanding a PVC is a one-line patch:

```bash
kubectl patch pvc dojo-data -n dojo-resize \
  -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
```

Or edit it interactively:

```bash
kubectl edit pvc dojo-data -n dojo-resize
# change storage: 1Gi → 2Gi under spec.resources.requests
```

You can only increase the request — **shrinking a PVC is not supported** by any CSI driver. If you need smaller: snapshot, delete, recreate, restore.

## Why this matters

In production, disk pressure is always a surprise. Having muscle memory for PVC expansion — and knowing which StorageClasses in your cluster support it (`kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.allowVolumeExpansion}{"\n"}{end}'`) — is the difference between a 2-minute config change and an emergency restore from backup.
