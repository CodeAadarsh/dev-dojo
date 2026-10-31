# Back Up the Brain

It's 02:00. A control-plane disk is throwing SMART errors and the cloud provider's auto-repair is about to recycle the node. Every object the cluster has ever known — Deployments, Secrets, CRDs, RBAC, the lot — lives in exactly one place: **etcd**. If that node evaporates without a snapshot, you don't get a *degraded* cluster. You get a **blank** one, and a three-day rebuild from whatever happens to be in Git.

This is the drill every cluster-admin interview probes and every real on-call eventually runs for real: **take a consistent etcd snapshot, land it on disk, and prove it's valid** — with the certs memorized, not googled.

## Where you are

The lab cluster is `kind` (cluster name `dojo`), so the control-plane "node" is just a Docker container named `dojo-control-plane`. etcd runs there as a static pod, and its client mTLS certs sit under `/etc/kubernetes/pki/etcd/`:

| File | Role |
|------|------|
| `/etc/kubernetes/pki/etcd/ca.crt` | CA that signed the etcd serving cert |
| `/etc/kubernetes/pki/etcd/server.crt` | client cert presented to etcd on `:2379` |
| `/etc/kubernetes/pki/etcd/server.key` | matching private key |

The setup script has already created the backup directory `/var/lib/etcd-backup/` **inside the node** — it does **not** take the snapshot. That part is yours.

## Mission

Produce a valid etcd snapshot at **`/var/lib/etcd-backup/snapshot.db` on the `dojo-control-plane` node**. The verifier accepts your work only when **both** of these are true:

1. **The file exists** — `docker exec dojo-control-plane test -f /var/lib/etcd-backup/snapshot.db` succeeds.
2. **It is a real etcd snapshot** — `ETCDCTL_API=3 etcdctl --write-out=table snapshot status /var/lib/etcd-backup/snapshot.db` succeeds (a truncated/garbage file fails this; `touch`ing the path will not fool it).

The canonical command, with the three mTLS files and `ETCDCTL_API=3`, is:

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

`snapshot save` talks to the **live** etcd on `:2379` and needs the certs. `snapshot status` reads a **local file** and needs no certs or endpoint — that asymmetry is the whole trick to the verifier.

## Why this matters

- A snapshot is a **consistent, point-in-time copy of the entire keyspace** — the only artifact that lets you rebuild the cluster's state rather than its shell. GitOps rebuilds what's declared in Git; it does **not** restore dynamically-created state (issued certs, leader leases, CRD instances written by operators, resources applied by hand).
- **A backup you have never restored is a hope, not a plan.** Running `snapshot status` is the cheapest possible verification that the bytes are a real snapshot before you ever trust them in a 02:00 restore.
- **A backup on the volume you're backing up is not a backup.** In the real world you'd `docker cp` / `scp` this file *off* the node immediately. In the lab we stop at "valid snapshot on the node," but the solution shows the off-node copy and the full stop → restore-to-fresh-dir → repoint-static-pod recovery flow.

When the snapshot exists and validates, run the verifier. It inspects the node directly and prints the flag only if the snapshot is real.
