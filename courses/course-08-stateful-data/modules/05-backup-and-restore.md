# Backup & Restore

> **Module 05 · Course 08** — The backup that has never been restored is not a backup; it's a feeling. This module covers the mechanics of getting data out of stateful workloads on Kubernetes, and — more importantly — the mechanics of getting it back.

The first question to ask about any backup strategy is not "how do I take the backup?" It is "what does a successful restore look like, and how long does it take?" Design backwards from the restore.

---

## Logical vs Physical Backups

The distinction matters enormously for databases:

| | Logical backup | Physical backup |
|---|---|---|
| **What** | SQL/data dump — rows, schemas, encoded text | Block-level copy of the storage volume |
| **Tool examples** | `pg_dump`, `mysqldump`, `mongodump` | `pg_basebackup`, VolumeSnapshot, storage-level snapshot |
| **Portable** | Yes — different versions, different storage classes | No — tied to storage driver, often same major version |
| **Consistency** | Application-consistent by default | Requires quiescing writes or crash-consistent at best |
| **Size/speed** | Slower; compressible | Fast (storage-layer); size of the data on disk |
| **Restore time** | Slow — replay every row | Fast — snapshot clone, mount, done |
| **Point-in-time** | Yes, with WAL/binlog archiving | Yes, with WAL archiving on top of base snapshot |

For most production database workloads you want **both**: a physical backup for fast full restores, and logical dumps or WAL archiving for point-in-time recovery (PITR) to any second in the last 30 days.

---

## VolumeSnapshots: the CSI Snapshot API

Kubernetes standardized volume snapshots in the CSI (Container Storage Interface) spec. The API is three resources:

```
VolumeSnapshotClass    — like StorageClass, defines which driver handles snapshots
VolumeSnapshot         — a request to snapshot a PVC (like PVC is a request for storage)
VolumeSnapshotContent  — the actual snapshot artifact (like PV is the actual storage)
```

The snapshot controller (a separate deployment you install alongside your CSI driver) reconciles VolumeSnapshot → VolumeSnapshotContent, mirroring how the PV controller handles PVC → PV.

```
┌─────────────┐  creates   ┌──────────────────────┐  binds   ┌───────────────────────┐
│ VolumeSnap- │ ────────>  │ VolumeSnapshotContent│ <──────  │   VolumeSnapshot      │
│ shotClass   │            │ (driver artifact)    │          │ (your request)        │
│             │            │ snapshotHandle: ...  │          │ source: my-pvc        │
└─────────────┘            └──────────────────────┘          └───────────────────────┘
```

### Taking a snapshot

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: pgdata-snap-20240915
  namespace: dojo-data
spec:
  volumeSnapshotClassName: csi-hostpath-snapclass   # use your driver's class
  source:
    persistentVolumeClaimName: pgdata-pg-main-1
```

```bash
kubectl apply -f snapshot.yaml
kubectl -n dojo-data get volumesnapshot pgdata-snap-20240915 -w
# READYTOUSE is false until the snapshot completes
kubectl -n dojo-data get volumesnapshot pgdata-snap-20240915 \
  -o jsonpath='{.status.readyToUse}{"\n"}'
# true
```

### Restoring from a snapshot

Create a new PVC with `dataSource` pointing to the snapshot:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pgdata-restored
  namespace: dojo-data
spec:
  storageClassName: standard
  dataSource:
    name: pgdata-snap-20240915
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
```

The CSI driver creates a volume pre-populated from the snapshot — no data copy, typically a CoW clone at the storage layer. For kind's `csi-hostpath` driver this is a local copy; for real cloud drivers (AWS EBS, GCP PD, Azure Disk) this is a storage-native snapshot with near-zero restore time.

---

## Application-Consistent Backups

A VolumeSnapshot taken while Postgres is actively writing is **crash-consistent** — it's safe if Postgres can replay WAL after a crash, and Postgres can — but it is *not* application-consistent. An application-consistent backup requires coordination with the application:

**Pattern 1 — quiesce + snapshot + unquiesce:**

```bash
# for Postgres: checkpoint flushes dirty pages to disk
kubectl -n dojo-data exec -it pg-main-1 -- \
  psql -U postgres -c "CHECKPOINT;"

# now take the snapshot (brief window of consistent state)
kubectl apply -f snapshot.yaml

# for MySQL you'd use FLUSH TABLES WITH READ LOCK; ... UNLOCK TABLES;
```

**Pattern 2 — WAL-based PITR (the professional answer):**

CloudNativePG, Barman, and most operator backup integrations use continuous WAL archiving. The base backup can be crash-consistent; the WAL archive fills in the gap. You restore to the exact LSN you need. This is how production PostgreSQL backup works.

```bash
# trigger an on-demand backup in CloudNativePG
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: pg-main-manual-20240915
  namespace: dojo-data
spec:
  cluster:
    name: pg-main
  method: barmanObjectStore
EOF

kubectl -n dojo-data get backup pg-main-manual-20240915 -w
# watch .status.phase: pending -> running -> completed
```

---

## Velero: Cluster-Level Backup

VolumeSnapshots back up individual PVCs. **Velero** backs up entire namespaces — or an entire cluster — as a unit: all the Kubernetes API objects (Deployments, ConfigMaps, Services, Secrets, PVCs) plus the underlying PV data.

This is the right tool for:
- Migrating a workload from one cluster to another
- Pre-upgrade snapshots of the whole cluster
- Disaster recovery when you need to recreate everything from scratch

### Install Velero (with the AWS/MinIO plugin — works with any S3-compatible backend)

```bash
# install the Velero CLI
brew install velero        # macOS
# or: https://github.com/vmware-tanzu/velero/releases

# install server-side into the cluster (using MinIO locally, S3 in prod)
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.9.0 \
  --bucket velero-backups \
  --secret-file ./credentials-velero \
  --use-volume-snapshots=true \
  --backup-location-config region=minio,s3ForcePathStyle=true,s3Url=http://minio.dojo-velero.svc:9000 \
  --snapshot-location-config region=minio

# credentials-velero file:
# [default]
# aws_access_key_id=minio
# aws_secret_access_key=minio123
```

### Take a backup

```bash
# back up the entire dojo-data namespace, including PV data
velero backup create pg-main-full \
  --include-namespaces dojo-data \
  --default-volumes-to-fs-backup \
  --wait

velero backup describe pg-main-full
velero backup logs pg-main-full
```

`--default-volumes-to-fs-backup` uses Velero's file-system backup (restic/kopia under the hood) to copy PV data to object storage. This is slower than a VolumeSnapshot but works on any storage class including `hostPath`.

### Schedule a recurring backup

```bash
velero schedule create daily-dojo-data \
  --schedule="0 2 * * *" \
  --include-namespaces dojo-data \
  --default-volumes-to-fs-backup \
  --ttl 720h        # retain for 30 days
```

---

## Testing Restores: the Part Everyone Skips

A backup you haven't restored is unverified. The restore test should be a scheduled operation, not a disaster-day surprise. Pattern for a safe, non-disruptive restore test:

```bash
# restore into a separate namespace so you don't touch production
velero restore create pg-main-restore-test \
  --from-backup pg-main-full \
  --namespace-mappings dojo-data:dojo-data-restored \
  --wait

# verify the restored namespace looks right
kubectl -n dojo-data-restored get pods,pvc,svc

# connect to the restored Postgres and run a sanity check query
kubectl -n dojo-data-restored exec -it pg-main-restored-1 -- \
  psql -U postgres -c "SELECT count(*) FROM pg_stat_user_tables;"

# measure restore time (logged by Velero)
velero restore describe pg-main-restore-test \
  -o json | grep -E '"completionTimestamp"|"startTimestamp"'

# clean up the test namespace
kubectl delete ns dojo-data-restored
```

Document: backup size, time to take, time to restore, row-count or checksum delta. This is your RTO measurement. Do it monthly, or after any infrastructure change.

---

## Debugging Backups

### Debugging: Snapshot Failures and Restore Failures

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `VolumeSnapshot.status.readyToUse` stays `false` | CSI driver doesn't support snapshots, or snapshot controller not installed | `kubectl get crd volumesnapshots.snapshot.storage.k8s.io` — missing means the snapshot CRDs aren't installed; check `kubectl -n kube-system get pods \| grep snapshot` |
| `VolumeSnapshot` created but `VolumeSnapshotContent` never appears | VolumeSnapshotClass doesn't match the PVC's provisioner | Compare `VolumeSnapshotClass.driver` to the PVC's StorageClass `provisioner` — they must match |
| Restored PVC from snapshot is empty | `dataSource` referenced a snapshot in `Terminating` state, or driver doesn't support cross-namespace restore | Check `kubectl get volumesnapshot -o yaml` for `readyToUse: false` or error conditions |
| Velero backup shows `PartiallyFailed` | One or more PVs backed up with errors (restic/kopia couldn't read a file) | `velero backup logs <name> \| grep error`; common cause is a pod writing while backup runs — add a pre-hook to quiesce |
| Velero restore: pods come up but PVCs stay `Pending` | StorageClass from source cluster doesn't exist in the target cluster | Add `--existing-resource-policy=update` and pre-create the StorageClass; or use a StorageClass mapping |
| CloudNativePG backup `failed` phase | S3 credentials wrong, bucket missing, or Barman can't reach the endpoint | `kubectl -n dojo-data describe backup <name>` shows the error; check the operator logs and the Barman container logs inside the pod |

```bash
# snapshot controller and CRD install status
kubectl -n kube-system get deploy snapshot-controller 2>/dev/null \
  || echo "snapshot-controller not installed"
kubectl get crd volumesnapshots.snapshot.storage.k8s.io 2>/dev/null \
  || echo "snapshot CRDs missing"

# check what snapshot classes exist and which provisioner they target
kubectl get volumesnapshotclass \
  -o custom-columns=NAME:.metadata.name,DRIVER:.driver

# Velero: list all backups and their status
velero backup get

# Velero: detailed error output for a failed backup
velero backup logs pg-main-full | grep -i "error\|fail"

# CloudNativePG backup diagnostics
kubectl -n dojo-data get backup -o wide
kubectl -n dojo-data describe backup pg-main-manual-20240915
kubectl -n cnpg-system logs deploy/cnpg-controller-manager \
  | grep -i "backup\|barman\|error" | tail -30
```

### Inconsistent Backup — What It Means and How to Detect It

An inconsistent backup captured writes mid-transaction. For crash-recoverable databases (Postgres, MySQL InnoDB) this is recoverable; for applications that don't have write-ahead logs, it can produce silent corruption.

Detection patterns:

```bash
# after restoring, check Postgres cluster status
kubectl -n dojo-data-restored exec -it pg-main-1 -- \
  psql -U postgres -c "SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn();"

# run the application's own consistency checks if available
# e.g., for Postgres: pg_dump --schema-only to verify schema integrity
kubectl -n dojo-data-restored exec -it pg-main-1 -- \
  pg_dump -U postgres --schema-only mydb > /dev/null && echo "schema ok"

# check for dirty pages / incomplete recovery in Postgres logs
kubectl -n dojo-data-restored logs pg-main-1 | grep -i "recovery\|consistent\|checkpoint"
```

> **War story.** On the LGTM pipeline at SAP, we had a Thanos Compactor backed by a PVC. The ops rotation ran a VolumeSnapshot at 2am, a time chosen to minimise load. Three months later a disk failure meant we needed that snapshot. The restore produced a Thanos block store where three blocks had overlapping series and the compactor had been mid-write when the snapshot landed. Compactor refused to start because the ULID sequence was corrupt. We had to resync from the metrics ingestors for a 6-hour window. The lesson: for any workload that writes continuously, a crash-consistent snapshot is *not enough* — you need either a quiesce hook or a WAL-based backup. We added a Velero pre-backup hook that sent a `SIGTERM` to the compactor, waited for it to exit cleanly, snapped, then restarted it. That's the procedure now.

---

## Checkpoint

You're solid on this module when you can:

1. Explain in one paragraph why you want both a physical backup and WAL archiving for a production Postgres cluster.
2. Draw the relationship between `VolumeSnapshotClass`, `VolumeSnapshot`, and `VolumeSnapshotContent`.
3. Name the two prerequisites (beyond just a CSI driver) needed to use VolumeSnapshots in a cluster.
4. Explain what `--default-volumes-to-fs-backup` does in Velero and when you'd use it over a VolumeSnapshot.
5. Write the `velero restore` command that restores a backup into a different namespace.
6. Diagnose a `VolumeSnapshot` whose `readyToUse` is stuck at `false`.
7. Explain why a crash-consistent snapshot of a Postgres PVC is still safe to restore, and in what scenario it is not.
8. State the minimum you should verify after every restore test.

➡ Next up: **Disaster Recovery & Data Migration** — when the cluster itself is the thing that failed.
