# Disaster Recovery & Data Migration

> **Module 06 · Course 08** — DR planning has two failure modes: never tested until a real disaster, and so overengineered it never ships. This module gives you the concrete mechanics — etcd restore, cross-cluster PV migration, zero-downtime schema changes — and the mental model for deciding how much insurance is enough.

---

## RPO and RTO: Design Goals, Not Aspirations

Every DR conversation starts with two numbers:

- **RPO (Recovery Point Objective)** — how much data loss is acceptable? "We can lose at most 1 hour of orders." This drives backup frequency.
- **RTO (Recovery Time Objective)** — how long can the system be down? "We must be back in 30 minutes." This drives infrastructure redundancy and automation.

The relationship between RPO/RTO and cost is roughly exponential — cutting RTO from 4 hours to 30 minutes might cost 2x; cutting it to 5 minutes might cost 10x. Define the numbers explicitly with the business before designing the system. "As fast as possible" is not an RPO.

| RPO | What it requires |
|-----|-----------------|
| Hours | Daily backups to object storage; restore from Velero or operator backup |
| Minutes | WAL/binlog archiving to object storage; PITR-capable operator |
| Seconds | Synchronous replication to a standby in a second AZ/region |
| Zero | Quorum-based distributed database (CockroachDB, Vitess) — no single primary to fail |

| RTO | What it requires |
|-----|-----------------|
| Hours | Manual restore procedure; runbook + trained human |
| 30 min | Automated restore into a warm standby cluster; tested regularly |
| 5 min | Hot standby cluster; traffic failover via DNS TTL or load balancer |
| Sub-minute | Active-active multi-region; application handles split writes |

Document your RPO/RTO targets in the same place as your backup schedule. If you can't point to both, you don't actually have a DR plan.

---

## Cross-Cluster and Cross-Region Strategies

Three architectural patterns, in increasing cost and complexity:

### Pattern 1: Backup + Restore (Cold Standby)

Object storage (S3, GCS) is the transport medium. The primary cluster archives WAL and base backups continuously. The DR cluster is created from scratch when needed, restored from object storage.

```
  Primary cluster (region A)          Object Storage
  ┌────────────────────────┐          ┌──────────────┐
  │  CloudNativePG         │ ────WAL► │  s3://backups│
  │  pg-main               │ ─base──► │  /pg-main/   │
  └────────────────────────┘          └──────┬───────┘
                                             │ restore on DR
                                      ┌──────▼───────┐
                                      │  DR cluster  │
                                      │  (region B)  │
                                      └──────────────┘
```

RPO: minutes (last WAL segment). RTO: 30–60 min (cluster boot + restore). Cost: low — no idle DR cluster running.

CloudNativePG recovery from an object store backup:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-dr-restore
  namespace: dojo-data-dr
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:16.3
  bootstrap:
    recovery:
      source: pg-main-backup
      recoveryTarget:
        targetTime: "2024-09-15 14:30:00"    # PITR to this moment
  externalClusters:
    - name: pg-main-backup
      barmanObjectStore:
        destinationPath: s3://my-bucket/pg-main
        s3Credentials:
          accessKeyId:
            name: pg-backup-creds
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: pg-backup-creds
            key: SECRET_ACCESS_KEY
  storage:
    size: 10Gi
```

### Pattern 2: Streaming Replica Across Clusters (Warm Standby)

Primary cluster streams WAL to a replica cluster in the DR region. Replica is running but not serving traffic. Failover promotes the replica to primary and flips DNS.

RPO: seconds (streaming lag). RTO: 1–5 min (promotion + DNS TTL). Cost: DR cluster runs idle but at replica scale.

CloudNativePG supports this via the `replica` bootstrap mode — the DR cluster's primary acts as a physical standby of the production cluster's primary.

### Pattern 3: Active-Active / Distributed Database

CockroachDB, YugabyteDB, or Vitess (MySQL sharding). Multi-region quorum writes; no single primary. Applications must handle distributed transaction semantics.

RPO: near-zero. RTO: near-zero (surviving nodes continue). Cost: high — every write pays the latency of cross-region quorum.

---

## Restoring from etcd

etcd is the source of truth for all Kubernetes state. If etcd is corrupted or all control-plane nodes are lost, you restore from an etcd snapshot. This is the cluster-level equivalent of a database restore.

### Taking an etcd snapshot

In a kind cluster, etcd runs as a static Pod on the control-plane container:

```bash
# snapshot etcd to a local file
docker exec dojo-control-plane sh -c \
  "ETCDCTL_API=3 etcdctl \
   --cacert=/etc/kubernetes/pki/etcd/ca.crt \
   --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key \
   snapshot save /tmp/etcd-snapshot.db"

# copy it out of the container
docker cp dojo-control-plane:/tmp/etcd-snapshot.db ./etcd-snapshot-$(date +%Y%m%d).db

# verify the snapshot is intact
ETCDCTL_API=3 etcdctl snapshot status ./etcd-snapshot-$(date +%Y%m%d).db --write-out=table
```

In a production cluster (kubeadm), `etcdctl` is typically available inside the etcd Pod:

```bash
kubectl -n kube-system exec -it etcd-<node-name> -- sh -c \
  "ETCDCTL_API=3 etcdctl \
   --cacert=/etc/kubernetes/pki/etcd/ca.crt \
   --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key \
   snapshot save /var/lib/etcd/snapshot.db"
```

### Restoring etcd

etcd restore is a multi-step operation because every etcd member must be restored to the same snapshot in a coordinated way. The procedure for a single-node control plane (kind / kubeadm dev cluster):

```bash
# 1. stop the API server and etcd (move static pod manifests away)
docker exec dojo-control-plane mv \
  /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/etcd.yaml.bak
docker exec dojo-control-plane mv \
  /etc/kubernetes/manifests/kube-apiserver.yaml \
  /etc/kubernetes/manifests/kube-apiserver.yaml.bak

# 2. restore the snapshot to a new data directory
docker cp ./etcd-snapshot-20240915.db dojo-control-plane:/tmp/etcd-snapshot.db
docker exec dojo-control-plane sh -c \
  "ETCDCTL_API=3 etcdctl snapshot restore /tmp/etcd-snapshot.db \
   --data-dir=/var/lib/etcd-restore \
   --name=dojo-control-plane \
   --initial-cluster=dojo-control-plane=https://127.0.0.1:2380 \
   --initial-advertise-peer-urls=https://127.0.0.1:2380"

# 3. point etcd static pod manifest at the restored data dir, then restore manifests
# (edit /etc/kubernetes/manifests/etcd.yaml: volumes.hostPath.path -> /var/lib/etcd-restore)
docker exec dojo-control-plane mv \
  /etc/kubernetes/manifests/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml
docker exec dojo-control-plane mv \
  /etc/kubernetes/manifests/kube-apiserver.yaml.bak \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

The API server will restart and reconnect to the restored etcd. All Kubernetes objects return to the state at snapshot time.

> **The key insight**: etcd restore alone does *not* restore your PV data. etcd holds the *metadata* — PVC objects, StorageClass objects, the fact that a PVC was bound to a PV. The actual bytes on the volume are wherever the CSI driver stored them. A full cluster restore requires etcd snapshot + PV data (Velero handles both together via its backup API).

---

## Zero-Downtime Schema and Data Migration

Moving data between clusters or applying breaking schema changes are the highest-risk events in a stateful system's lifecycle. The safest approach is to never require downtime.

### The Expand-Contract Migration Pattern

Also called "parallel change." It is the only safe way to make a breaking schema change without downtime:

```
Phase 1 — EXPAND (additive only):
  - Add the new column / table / field. Make it nullable or give it a default.
  - Deploy v2 of the application that writes to BOTH old and new column.
  - The old column still works; old app version still works. Zero risk.

Phase 2 — MIGRATE (backfill):
  - Run a background job that backfills the new column for existing rows.
  - Verify count(new_col IS NULL) == 0 before proceeding.

Phase 3 — CONTRACT (drop old):
  - Deploy v3 of the application that reads/writes ONLY the new column.
  - Once v3 is the only version running (confirmed in rollout), drop the old column.
```

Each phase is independently deployable and rollback-safe. The only risky step is dropping the old column, and by that point no code references it.

Example in practice — renaming a column `user_email` to `email`:

```sql
-- Phase 1: EXPAND
ALTER TABLE users ADD COLUMN email VARCHAR(255);
-- v2 app writes to both user_email and email

-- Phase 2: MIGRATE (run in batches to avoid lock)
UPDATE users SET email = user_email WHERE email IS NULL LIMIT 10000;
-- repeat until complete; check: SELECT COUNT(*) FROM users WHERE email IS NULL;

-- Phase 3: CONTRACT (after v3 is fully deployed)
ALTER TABLE users DROP COLUMN user_email;
```

### Cross-Cluster Migration with Velero

Moving a stateful workload from one cluster to another:

```bash
# on source cluster: backup the namespace
velero backup create migrate-dojo-data \
  --include-namespaces dojo-data \
  --default-volumes-to-fs-backup \
  --wait

# on destination cluster: ensure the same Velero backup location is configured
# then restore
velero restore create migrate-dojo-data-restore \
  --from-backup migrate-dojo-data \
  --wait

# verify the restored workload
kubectl -n dojo-data get pods,pvc,svc
```

If the StorageClass names differ between clusters, use a StorageClass mapping:

```bash
velero restore create migrate-dojo-data-restore \
  --from-backup migrate-dojo-data \
  --storage-class-map '{"standard":"gp3"}' \
  --wait
```

### Online PV Migration via Resync

When you need to migrate PV data to a new StorageClass within the same cluster (e.g., from slow HDD to fast SSD) without downtime:

```bash
# 1. scale down the stateful workload
kubectl -n dojo-data scale statefulset pg-main --replicas=0

# 2. create a new PVC with the target StorageClass
kubectl -n dojo-data apply -f pgdata-fast-ssd.yaml   # 10Gi, storageClass: fast-ssd

# 3. copy data using a migration pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pv-migrate
  namespace: dojo-data
spec:
  restartPolicy: Never
  containers:
    - name: rsync
      image: alpine:3.19
      command: ["sh", "-c", "apk add rsync && rsync -av /src/ /dst/"]
      volumeMounts:
        - name: src
          mountPath: /src
        - name: dst
          mountPath: /dst
  volumes:
    - name: src
      persistentVolumeClaim:
        claimName: pgdata-pg-main-1
    - name: dst
      persistentVolumeClaim:
        claimName: pgdata-fast-ssd
EOF

kubectl -n dojo-data wait --for=condition=Succeeded pod/pv-migrate --timeout=30m

# 4. update the StatefulSet to use the new PVC, scale back up
# (StatefulSet volumeClaimTemplates are immutable — patch the pod template
# to use an existing PVC by name via volumeClaimTemplates workaround or
# re-create the StatefulSet with the corrected spec)
kubectl -n dojo-data scale statefulset pg-main --replicas=3
```

---

## Debugging DR and Migration

### Debugging: Partial Restore, Data Drift, and Migration Lock Contention

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Velero restore shows `PartiallyFailed`; some pods running, PVCs missing | Restic/kopia backup of one PV failed silently | `velero restore logs <name> \| grep error`; retake the backup after fixing the PV error, or restore the specific resources with `--include-resources pvc` separately |
| CloudNativePG PITR restore diverges from expected row count | `targetTime` lands in a hot WAL segment not yet uploaded to object storage | Restore to `targetLSN` instead of `targetTime`; verify WAL archive lag with `pg_stat_archiver` before snapshotting |
| Rows in old and new column disagree after backfill | Backfill ran while application was writing — race condition | Re-run backfill; add a WHERE clause + a final count check before promoting v3; use transactions |
| Schema migration `ALTER TABLE` hangs indefinitely | Long-running transaction holds a lock on the table | `SELECT pid, state, wait_event_type, query FROM pg_stat_activity WHERE wait_event_type='Lock'`; identify and cancel the blocking pid |
| etcd restore: API server starts but shows stale objects | Snapshot was taken before recent object changes | Accept the data loss (it's bounded to the snapshot age); or replay changes from application logs |
| PV migrate pod copies but database won't start on new PVC | File permissions or owner mismatch between rsync source and dest | Check `ls -la /dst` inside the pod; Postgres needs `$PGDATA` owned by uid 999 (postgres); add `--chown` to rsync or run `chown -R 999:999 /dst` |

```bash
# diagnose a Postgres lock contention during migration
kubectl -n dojo-data exec -it pg-main-1 -- psql -U postgres -c "
  SELECT pid, usename, state, wait_event_type, wait_event, left(query, 80) as query
  FROM pg_stat_activity
  WHERE wait_event_type = 'Lock'
  ORDER BY state;
"

# cancel a blocking query (not terminate — kinder first)
kubectl -n dojo-data exec -it pg-main-1 -- psql -U postgres -c \
  "SELECT pg_cancel_backend(<pid>);"

# check WAL archive lag before PITR-based DR
kubectl -n dojo-data exec -it pg-main-1 -- psql -U postgres -c "
  SELECT archived_count, last_archived_wal,
         EXTRACT(EPOCH FROM now() - last_archived_time) AS lag_seconds,
         failed_count, last_failed_wal
  FROM pg_stat_archiver;
"

# Velero: check what resources a backup captured
velero backup describe pg-main-full --details | grep -A5 "Resource List"

# inspect etcd snapshot contents (without restoring)
ETCDCTL_API=3 etcdctl snapshot status ./etcd-snapshot.db --write-out=table

# check a partial Velero restore: list what was and wasn't restored
velero restore describe migrate-dojo-data-restore --details \
  | grep -E "Phase:|Failed:|Succeeded:"
```

> **War story.** At SAP we migrated a production Postgres from a managed RDS-equivalent to a CloudNativePG cluster on K8s. The plan was a logical dump (`pg_dump`) + restore + cutover. The database was 180GB. The dump finished in 90 minutes. The restore ran for 4 hours — then failed at 98% with a disk-full error. We hadn't accounted for WAL generated by the restore itself inflating temp space. We fixed the disk, resumed from the dump, completed the restore — but the cutover window had slipped by 6 hours, past the agreed maintenance window. The post-mortem had two action items: always test restore on a disk that matches prod capacity (not a dev-sized PVC), and switch to a physical backup method (pg_basebackup + WAL) for databases above 50GB. We now use CloudNativePG's `bootstrap.recovery` path for all migrations above that threshold: it restores via streaming replication, which is incremental, resumable, and doesn't require a single maintenance window. Size your restore environment before you need it.

---

## Checkpoint

You're solid on this module when you can:

1. Define RPO and RTO and explain the tradeoff between each target and cost.
2. Choose between Cold Standby, Warm Standby, and Active-Active for a given RPO/RTO requirement, and justify the choice.
3. List the exact commands to take an etcd snapshot from inside a kind cluster's control-plane container.
4. Explain why restoring etcd does not restore PV data, and what additional step is needed for a full cluster recovery.
5. Describe the three phases of an expand-contract migration and identify which phase is safe to roll back.
6. Diagnose a hanging `ALTER TABLE` by querying `pg_stat_activity` and identify the blocking pid.
7. Restore a Velero backup into a different namespace and verify the restored workload.
8. Explain why a Postgres PITR restore using `targetTime` can diverge if WAL archiving has lag.

➡ This completes the core Stateful Workloads track. You now have the operator, backup, and DR pieces needed to run data on Kubernetes with the same rigour as a dedicated DBA team.
