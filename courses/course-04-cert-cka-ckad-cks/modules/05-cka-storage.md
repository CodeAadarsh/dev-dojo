# CKA: Storage

> **Module 05 · Course 04** — Storage tasks are short but trip people on one thing: *binding*. A pod waits for a PVC, a PVC waits for a PV (or a StorageClass to make one). If any link in that chain is wrong, the pod sits `Pending` forever. Learn to read the chain backwards.

## The binding chain

```
Pod ──uses──▶ PVC (a request: size + accessMode + storageClass)
                 │ bound to
                 ▼
               PV (actual storage) ── or ── StorageClass ──dynamically provisions──▶ PV
```

- **PV** = a piece of storage (admin-provisioned or dynamically created).
- **PVC** = a *claim* — "I want 1Gi, RWO, class standard."
- **StorageClass** = a factory that creates PVs on demand when a PVC asks for it.

kind ships a default StorageClass named **`standard`** (the local-path provisioner), so dynamic provisioning "just works" for labs.

## Access modes (memorize the abbreviations)

| Mode | Short | Meaning |
|------|-------|---------|
| ReadWriteOnce | RWO | one **node** can mount read-write (most block storage) |
| ReadOnlyMany | ROX | many nodes mount read-only |
| ReadWriteMany | RWX | many nodes mount read-write (NFS/CephFS) |
| ReadWriteOncePod | RWOP | exactly one **pod** |

A PVC binds to a PV only if the PV's capacity ≥ request **and** access mode matches **and** storageClass matches.

## Reclaim policy

- `Delete` (default for dynamic): delete the PVC → the PV and data are deleted.
- `Retain`: PV sticks around after the PVC is gone (manual cleanup) — use for data you can't lose.

## PVC + Pod (the common exam shape)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: data, namespace: app }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
  storageClassName: standard
---
apiVersion: v1
kind: Pod
metadata: { name: app, namespace: app }
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh","-c","sleep 3600"]
      volumeMounts: [{ name: d, mountPath: /data }]
  volumes:
    - name: d
      persistentVolumeClaim: { claimName: data }
```

## StatefulSets & volumeClaimTemplates

A Deployment with a single PVC shares one volume across all replicas (usually wrong for stateful apps). A **StatefulSet** uses `volumeClaimTemplates` to give **each** pod its **own** PVC (`data-web-0`, `data-web-1`, …) with a stable identity. That's how databases keep per-replica data.

## Debugging storage

| Symptom | Likely cause | Diagnose |
|---------|--------------|----------|
| Pod stuck `Pending` | PVC unbound | `kubectl get pvc` → status `Pending`? |
| PVC `Pending` | no matching PV, bad storageClass, no provisioner | `kubectl describe pvc <name>` (events) |
| Data gone after restart | used `emptyDir`, or reclaim `Delete` | check the volume type |
| `volume node affinity conflict` | PV pinned to a node the pod can't use | `kubectl describe pv` |

```bash
kubectl get pvc,pv
kubectl describe pvc data        # the Events explain WHY it won't bind
kubectl get storageclass         # is there a (default) class?
```

> **War story:** a StatefulSet stuck Pending on a fresh cluster. `describe pvc` said `no persistent volumes available for this claim and no storage class is set`. The cluster had **no default StorageClass**. Either set `storageClassName` explicitly on the PVC or mark a class default with the `storageclass.kubernetes.io/is-default-class` annotation.

## Checkpoint

1. Draw the Pod→PVC→PV/StorageClass chain and name what binds to what.
2. Explain the four access modes by abbreviation.
3. From `kubectl get pvc` showing `Pending`, list the three usual causes.
4. Say why a StatefulSet uses volumeClaimTemplates instead of one shared PVC.
5. Name the kind default StorageClass.

➡ Next: **CKS: Security Essentials** — hardening, the fastest-growing exam.
