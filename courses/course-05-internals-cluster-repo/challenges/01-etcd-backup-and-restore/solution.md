# Solution — Back Up the Brain

The flag is `KUBE{etcd_snapshot_is_the_only_real_dr}`.

## The one command that solves it

```bash
docker exec dojo-control-plane sh -c '
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    snapshot save /var/lib/etcd-backup/snapshot.db
'
```

Then prove it's real (this is exactly what the verifier does — `snapshot status` needs no certs because it reads the local file):

```bash
docker exec dojo-control-plane sh -c \
  'ETCDCTL_API=3 etcdctl --write-out=table snapshot status /var/lib/etcd-backup/snapshot.db'
```

```
+----------+----------+------------+------------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+----------+----------+------------+------------+
| 3f2a9c1b |    24187 |       1043 |     4.1 MB |
+----------+----------+------------+------------+
```

Run the verifier:

```bash
bash courses/course-05-internals-cluster-repo/challenges/01-etcd-backup-and-restore/verify.sh
```

## Why each piece is correct

- **`ETCDCTL_API=3`** — API v2 and v3 are different data models with different command surfaces. Snapshots are a v3 feature; without this var older `etcdctl` builds default to v2 and `snapshot save` either disappears or targets the wrong keyspace.
- **The three `--cacert` / `--cert` / `--key` flags** — etcd on `:2379` is mutual-TLS. `--cacert` lets your client verify etcd's serving cert; `--cert`/`--key` are the client identity etcd checks. Miss any one and you get a TLS handshake error, not an auth error — a useful tell when debugging.
- **`--endpoints=https://127.0.0.1:2379`** — `snapshot save` is a *live* read of the running member, so it must reach the server. (`snapshot status`, `snapshot restore`, by contrast, operate on a file and need neither endpoint nor certs.)
- **Path `/var/lib/etcd-backup/snapshot.db`** — an arbitrary known location the setup script pre-created on the node. etcd will refuse to overwrite an existing snapshot path, so re-running after a successful save errors with `file already exists`; `rm` it first or write a timestamped name.

## In the real world you don't stop here

A backup that lives on the disk you're protecting dies with that disk. Copy it off the node immediately:

```bash
docker cp dojo-control-plane:/var/lib/etcd-backup/snapshot.db ./etcd-snapshot-$(date +%F).db
```

In production this is a scheduled job (a CronJob with the etcd certs mounted, or the node's own cron) that ships to object storage off-cluster, with retention and — critically — a **periodic restore rehearsal**.

## The restore flow you're actually backing up *for*

Restore does **not** write into a running etcd. You restore to a *fresh* data directory and repoint etcd at it:

```bash
# 1) restore the snapshot to a NEW data dir (no certs/endpoint needed)
docker exec dojo-control-plane sh -c '
  ETCDCTL_API=3 etcdctl snapshot restore /var/lib/etcd-backup/snapshot.db \
    --data-dir /var/lib/etcd-restored
'
```

```bash
# 2) on the node: stop etcd by moving its static-pod manifest aside,
#    swap the data dir, then put the manifest back. kubelet watches
#    /etc/kubernetes/manifests and restarts the static pod automatically.
docker exec dojo-control-plane sh -c '
  mv /etc/kubernetes/manifests/etcd.yaml /tmp/etcd.yaml
  sleep 5                                   # let kubelet tear the old etcd down
  mv /var/lib/etcd /var/lib/etcd.bak
  mv /var/lib/etcd-restored /var/lib/etcd
  mv /tmp/etcd.yaml /etc/kubernetes/manifests/etcd.yaml
'
```

For a multi-node etcd you restore on **every** member with matching `--initial-cluster`, `--initial-advertise-peer-urls`, and `--name` flags, or the members refuse to form a quorum. Restoring one member and letting the others "catch up" is a classic way to get a split-brain cluster.

## Security framing — the backup is a crown-jewel file

An etcd snapshot is a complete, offline copy of **every Secret in the cluster** (base64, and plaintext unless you enabled encryption-at-rest). Whoever holds the snapshot holds every credential the cluster has ever stored, with no RBAC in the way. Treat the snapshot file with the same controls as the cluster's root key: encrypt it at rest in object storage, scope access tightly, and prefer encryption-at-rest on etcd so the snapshot's Secrets are ciphertext too.
