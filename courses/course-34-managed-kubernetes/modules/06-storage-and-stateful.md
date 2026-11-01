# Cloud Storage & Stateful

> **Module 06 · Course 34** — Stateless pods can land anywhere and die without consequence. Stateful workloads are different: they carry data that outlives the pod, and that data needs to be in the right AZ, on the right disk type, and — when something goes wrong — recoverable. This module is about getting cloud storage right the first time, because the failure modes (data stuck in the wrong zone, an unrecoverable snapshot, a PVC that will never bind) are the kind that cost you hours during an incident.

---

## How cloud storage connects to Kubernetes: the CSI model

Before CSI (Container Storage Interface), each cloud provider had a baked-in volume driver in the kubelet binary. CSI moved this out of the Kubernetes core: a cloud-specific controller pod runs in your cluster and handles the volume lifecycle on behalf of the kubelet.

```
┌───────────────────────────────────────────────────────────────┐
│                    your cluster                               │
│                                                               │
│  Pod  ──── PVC ──── PV ────────────────────────────────────── │
│                            CSI driver pod                     │
│                            (e.g. ebs.csi.aws.com)            │
│                                │                              │
└────────────────────────────────┼──────────────────────────────┘
                                 │ cloud API call
                                 ▼
                       ┌──────────────────┐
                       │  AWS EBS / GCP   │
                       │  Persistent Disk │
                       │  / Azure Disk    │
                       └──────────────────┘
```

Each cloud's CSI driver is a Deployment (the controller) + a DaemonSet (the node agent). The node agent handles mount/unmount on each node; the controller handles create/delete/snapshot at the cloud level.

| Cloud | Default CSI driver | StorageClass provisioner |
|-------|--------------------|--------------------------|
| AWS EKS | `ebs.csi.aws.com` | `ebs.csi.aws.com` |
| GKE | `pd.csi.storage.gke.io` | `pd.csi.storage.gke.io` |
| AKS | `disk.csi.azure.com` | `disk.csi.azure.com` |

> **The in-tree drivers are deprecated.** Older clusters used `kubernetes.io/aws-ebs`, `kubernetes.io/gce-pd`, etc. — these are in-tree drivers built into the kubelet. Managed clusters (EKS 1.23+, GKE 1.26+) migrated to CSI drivers. If you see in-tree provisioners in a StorageClass, the cluster is old or the migration hasn't run. In-tree → CSI migration is automatic on new clusters but requires a migration job on old ones.

---

## StorageClasses: what you're actually choosing

A StorageClass is not just a name — it encodes the disk type, filesystem, reclaim policy, and binding mode. The defaults on every cloud are usable but rarely optimal.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-retain
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"   # MiB/s; gp3 baseline, can go to 1000
  encrypted: "true"
reclaimPolicy: Retain           # don't delete the EBS volume when the PVC is deleted
volumeBindingMode: WaitForFirstConsumer  # critical for AZ pinning — see below
allowVolumeExpansion: true
```

**`volumeBindingMode: WaitForFirstConsumer`** is the single most important field for multi-AZ clusters. Without it:

```
WaitForFirstConsumer = off (default: Immediate):
  PVC created → EBS volume provisioned in AZ us-east-1a
  Pod scheduled by the scheduler → lands on node in us-east-1b
  Mount fails: EBS volumes are AZ-local and cannot cross AZs
  → pod stuck in ContainerCreating, volume inaccessible

WaitForFirstConsumer = on:
  PVC created → no volume yet (binding deferred)
  Pod scheduled → scheduler picks a node in us-east-1a
  Volume provisioned in us-east-1a (same AZ as the node)
  → mount succeeds
```

Always use `WaitForFirstConsumer` for zonal disks (EBS, GCP PD, Azure Disk). Only use `Immediate` for distributed storage systems (Ceph, Portworx) that are not AZ-local.

---

## Volume expansion

Cloud disks support online expansion (EBS gp3, GCP pd-ssd, Azure managed disk). Enable it in the StorageClass (`allowVolumeExpansion: true`), then:

```bash
# patch the PVC request size — the CSI driver calls the cloud API to resize
kubectl patch pvc my-data-pvc -p '{"spec":{"resources":{"requests":{"storage":"100Gi"}}}}'

# watch the expansion complete
kubectl describe pvc my-data-pvc | grep -A 3 Conditions
# Condition: FileSystemResizePending → then: Resizing → then: gone (done)
```

What actually happens:
1. Kubernetes updates the PVC `spec.resources.requests.storage`.
2. The CSI external-resizer sidecar detects the change and calls `ControllerExpandVolume` on the driver → the cloud disk grows.
3. On the next kubelet sync, `NodeExpandVolume` resizes the filesystem inside the pod's mount point.

You don't need to delete the pod for an online resize on a running pod (as long as the filesystem supports it — ext4 and xfs do). For volumes not currently mounted, the filesystem resize happens at next mount.

---

## Zonal pinning: locking a StatefulSet to an AZ

When you run a single-replica stateful workload (Postgres, Redis without replication), you want it and its data to stay in the same AZ across restarts. Use `topologyKey: topology.kubernetes.io/zone` in a `nodeAffinity`:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  replicas: 1
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      storageClassName: fast-retain
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 50Gi
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: topology.kubernetes.io/zone
                operator: In
                values: ["us-east-1a"]  # pin to the AZ where the PV was created
      containers:
      - name: postgres
        image: postgres:16-alpine
        env:
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: pg-secret
              key: password
```

The problem with hardcoding an AZ: if us-east-1a has an outage, your pod won't schedule anywhere. For true HA, use a managed database service or a replicated storage system (EFS, Ceph) instead.

---

## Snapshots and backups with Velero

**Volume Snapshots (CSI-native)** create a cloud-level point-in-time copy of a disk:

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: postgres-snapshot-2026-11
spec:
  volumeSnapshotClassName: csi-aws-vsc
  source:
    persistentVolumeClaimName: data-postgres-0
```

```bash
# watch the snapshot complete
kubectl get volumesnapshot postgres-snapshot-2026-11 -w
# READYTOUSE becomes true when the cloud snapshot is done

# restore: create a new PVC from the snapshot
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-restore
spec:
  storageClassName: fast-retain
  dataSource:
    name: postgres-snapshot-2026-11
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 50Gi
EOF
```

**Velero** goes a level higher: it snapshots volumes *and* backs up the Kubernetes object manifests (Deployments, Services, ConfigMaps, Secrets) to object storage (S3/GCS/Azure Blob), so you can restore an entire namespace — objects and data — into a different cluster.

Velero backup/restore flow:

```
velero backup create prod-backup --include-namespaces=production \
  --snapshot-volumes --storage-location default
  │
  ├── dumps every Kubernetes object in the namespace to S3
  └── triggers a CSI VolumeSnapshot for each PVC → snapshot ID stored in backup

velero restore create --from-backup prod-backup \
  --namespace-mappings production:production-dr \
  --restore-volumes
  │
  ├── applies all Kubernetes objects into the new namespace
  └── creates new PVCs from the snapshot IDs (cross-region only if snapshots were copied)
```

---

## Managed vs in-cluster databases

This is a real architectural decision, not a "it depends" hand-wave. Here's the concrete trade-off:

| Dimension | Managed (RDS, Cloud SQL, Azure DB) | In-cluster (StatefulSet + PVC) |
|-----------|-------------------------------------|-------------------------------|
| HA & failover | Automatic (Multi-AZ, <1 min failover) | You build it (replication, Operator, chaos-test it) |
| Backups | Point-in-time recovery built in | Velero + CSI snapshots — you operate them |
| Upgrades | Managed rolling upgrade, minimal window | You pick the Operator, test upgrade paths |
| Cost | Higher unit price; no EC2 for DB | Cheaper instances; your eng time is the hidden cost |
| Access | VPC endpoint or private link | ClusterIP / DNS — no extra networking |
| Portability | Cloud-specific | Same YAML on any cluster |

For a small team (< 5 engineers), managed wins every time: the ops burden of running a production Postgres inside Kubernetes — replication, WAL archiving, point-in-time recovery, major version upgrades — is a full-time job. Use RDS or Cloud SQL and spend your bandwidth on the product.

For a large team running many small services with short-lived databases, or for cost optimization at scale, running with a battle-tested Operator (CloudNativePG, Zalando Postgres Operator) can pay off.

> **The case against in-cluster Postgres (from experience).** A team I know ran Postgres in-cluster on EKS with a custom StatefulSet (no Operator). The disk was gp2 in us-east-1a. During a rebalance, the scheduler tried to move the pod to us-east-1b. Volume couldn't follow. The pod was stuck `ContainerCreating` for 47 minutes while the team debugged the AZ mismatch. The root fix was adding `WaitForFirstConsumer` and node affinity — but the real lesson was "the Operator would have handled this." If you run databases in-cluster, use a mature Operator that owns the PVC lifecycle.

---

## Debugging cloud storage

### Volume AZ mismatch (the most common mistake)

```bash
# See why a pod is stuck ContainerCreating
kubectl describe pod <name> | grep -A 10 Events
# Event: AttachVolume.Attach failed: volume ... is not in the same AZ as node

# Find which AZ the PV was provisioned in
kubectl get pv <pv-name> -o jsonpath='{.spec.nodeAffinity}'
# {"required":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"topology.kubernetes.io/zone","operator":"In","values":["us-east-1a"]}]}]}}

# Find which AZ the node is in
kubectl get node <node-name> -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'

# Fix: delete the PVC (data loss! only for dev/test) and re-create with WaitForFirstConsumer
# OR: add node affinity to force the pod onto the correct AZ
```

For production, if data is on a PV in us-east-1a, add a `nodeAffinity` rule to the pod spec that pins it to nodes in us-east-1a. Don't fight the AZ boundary — go with it.

### PVC stuck in Pending

```bash
kubectl describe pvc <name>
# Events section — look for:
# "no volume plugin matched" → wrong StorageClass name or provisioner not installed
# "failed to provision volume" → CSI driver error, check IAM/permissions
# "waiting for first consumer" → this is normal for WaitForFirstConsumer until a pod is scheduled

# Check the CSI driver is running
kubectl -n kube-system get pods | grep csi

# Check the CSI driver logs
kubectl -n kube-system logs deployment/ebs-csi-controller -c csi-provisioner | tail -30
```

Permissions are the most common root cause for "failed to provision" on EKS. The CSI driver's ServiceAccount needs the `AmazonEBSCSIDriverPolicy` IAM policy via IRSA. If the annotation is missing or wrong:

```bash
kubectl -n kube-system get sa ebs-csi-controller-sa -o jsonpath='{.metadata.annotations}'
# should contain: eks.amazonaws.com/role-arn: arn:aws:iam::...
```

### Snapshot / restore gotchas

**Snapshot not completing.** A snapshot stuck in `ReadyToUse: false` usually means:
- The `VolumeSnapshotClass` `deletionPolicy` is `Delete` and the underlying cloud snapshot was deleted manually — the object is now orphaned.
- The CSI driver doesn't have `snapshot.storage.k8s.io` CRDs installed — on self-managed clusters you must install the snapshot controller separately.

```bash
kubectl get volumesnapshotclass
kubectl describe volumesnapshot <name> | grep -A 10 Status
kubectl -n kube-system logs deploy/snapshot-controller --tail=50 | grep -i error
```

**Restore into wrong StorageClass.** When you restore a PVC from a snapshot, the new PVC must reference a StorageClass with `allowVolumeExpansion` and the same provisioner. A restore into a StorageClass in a different region will silently create a PV that can't be mounted because the snapshot doesn't exist in that region.

---

## Checkpoint

You're ready for the storage challenges when you can, without looking anything up:

1. Name the CSI driver provisioner string for EBS, GCP PD, and Azure Disk.
2. Explain in two sentences why `volumeBindingMode: WaitForFirstConsumer` is required for multi-AZ clusters with zonal disks.
3. Describe the two steps that happen when you `kubectl patch pvc` to expand storage (cloud level vs. node level).
4. Write the `nodeAffinity` stanza that pins a pod to `us-east-1a` — including the exact label key.
5. List three reasons to prefer a managed database service over an in-cluster StatefulSet, and one reason to choose in-cluster.
6. Describe the difference between a CSI VolumeSnapshot and a Velero backup, and when you'd want each.
7. Diagnose a pod stuck in `ContainerCreating` with "AttachVolume failed: volume is not in the same AZ" — what are the two ways to fix it?
8. Identify the permission/annotation check for a PVC stuck in "failed to provision" on EKS.

➡ Next up: **Cost & Operations** — right-sizing, spot strategy, upgrade playbooks, and closing the FinOps loop.
