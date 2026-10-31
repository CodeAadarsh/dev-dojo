# etcd: The Cluster's Memory

> **Module 04 · Course 05** — Every object you've ever `kubectl apply`-ed lives in exactly one place: a single, consistent, replicated key-value store called etcd. Lose it without a backup and the cluster is gone — not degraded, *gone*. This module takes you inside `/registry`, shows you the "encrypted at rest is a lie by default" reality, and drills the one operational skill every cluster-admin interview probes: snapshot, restore, defrag.

You run clusters at work, so you already know etcd *exists*. What separates competent from expert is knowing what it stores byte-for-byte, why it gets slow, how quorum math decides whether your control plane is alive or a brick, and the exact `etcdctl` incantations to save and restore it under pressure — with the certs memorized, not googled.

---

## What etcd actually is

etcd is a distributed key-value store built on the **Raft** consensus protocol. The Kubernetes API server is its *only* client — nothing else in the cluster talks to etcd directly. Everything flows through this choke point:

```
  kubectl / controllers / kubelet
             │  (HTTPS, authn/authz, admission, validation)
             ▼
    ┌──────────────────┐        gRPC over mTLS (:2379)
    │   kube-apiserver  │ ─────────────────────────────►  ┌─────────┐
    │  (the ONLY etcd   │ ◄─────────────────────────────  │  etcd   │
    │     client)       │        watch streams            │ (Raft)  │
    └──────────────────┘                                  └─────────┘
             ▲                                                 │
             │  everything is a key under /registry/...        ▼
      no component bypasses the API server              write-ahead log + boltdb
```

Two consequences matter immediately:

- **The API server's `--etcd-servers` flag is a trust boundary.** Anyone who can reach `:2379` with the client certs skips *all* RBAC, admission, and validation. That's why node access ≈ full cluster compromise.
- **etcd is a watch engine, not just a database.** The API server holds long-lived `watch` streams; controllers react to etcd change notifications. A slow etcd doesn't just slow writes — it stalls every reconcile loop in the cluster.

---

## What's stored under `/registry`

Kubernetes stores every object as a key whose path mirrors the API: `/registry/<resource>/<namespace>/<name>`. The value is the serialized object — by default **protobuf**, not JSON.

Get onto the control-plane node (remember: in kind the node is just a container) and look. The etcd client certs live under `/etc/kubernetes/pki/etcd/`:

```bash
# shorthand: etcdctl needs API v3 + the three mTLS files, every single time
docker exec -it dojo-control-plane sh -c '
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/ --prefix --keys-only | head -40
'
```

> **Where does `etcdctl` live?** The binary ships *inside* the etcd static-pod container image, not always on the node's host PATH. On kind it is reliably reachable via the pod:
> ```bash
> kubectl -n kube-system exec -it etcd-dojo-control-plane -- sh
> # now etcdctl + the same /etc/kubernetes/pki/etcd certs are present
> ```
> Use whichever lands you a shell with `etcdctl` and the certs. The rest of this module writes `docker exec dojo-control-plane sh -c '…'` for brevity.

You'll see keys like:

```
/registry/pods/dojo-leaky/billing-7c9f...
/registry/secrets/dojo-leaky/app-config
/registry/deployments/default/web
/registry/services/endpoints/kube-system/kube-dns
/registry/leases/kube-node-lease/dojo-worker
```

| Prefix | Holds |
|--------|-------|
| `/registry/pods/<ns>/<name>` | every Pod spec+status |
| `/registry/secrets/<ns>/<name>` | Secrets (base64 value, **plaintext** unless you configured encryption-at-rest) |
| `/registry/<crd-group>/<kind>/…` | your CRD objects (same shape as built-ins) |
| `/registry/leases/…` | leader-election + node heartbeats (very high write churn) |
| `/registry/events/…` | Events — noisy, TTL'd, the #1 cause of etcd bloat |

### The "encrypted at rest is a lie by default" reality

Pull a Secret straight from etcd and you get plaintext:

```bash
docker exec -it dojo-control-plane sh -c '
  ETCDCTL_API=3 etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/dojo-leaky/app-config
' | strings | grep -i kube
```

The bytes are protobuf-wrapped but the Secret value is **not encrypted** — it's sitting there for anyone with the etcd certs. "It's in a Secret" is not a security control against someone who reached etcd.

The fix is an `EncryptionConfiguration` passed to the API server via `--encryption-provider-config`. A real one, using a KMS or `aescbc` provider:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: ["secrets"]
    providers:
      - aescbc:                       # symmetric key, better than identity
          keys:
            - name: key1
              secret: <base64-32-byte-key>
      - identity: {}                  # fallback so existing plaintext still reads
```

A critical gotcha: enabling encryption does **not** rewrite existing Secrets. They stay plaintext in etcd until re-written. You must force a rewrite:

```bash
kubectl get secrets -A -o json | kubectl replace -f -
```

After that, the same `etcdctl get` returns ciphertext starting with `k8s:enc:aescbc:v1:`.

---

## The one skill interviews probe: snapshot, restore, defrag

### endpoint status / health — read this first, always

```bash
docker exec -it dojo-control-plane sh -c '
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint status --write-out=table
'
```

The table's columns are the whole operational dashboard: **DB SIZE** (on-disk, grows with churn and never shrinks until you defrag), **IS LEADER**, **RAFT TERM** (bumps on every leader election — a climbing term means flapping), and **ERRORS** (look for `alarm:NOSPACE`).

### snapshot save

```bash
docker exec -it dojo-control-plane sh -c '
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    snapshot save /var/lib/etcd-snapshot.db
'
# copy it OFF the node — a backup on the node you're backing up is not a backup
docker cp dojo-control-plane:/var/lib/etcd-snapshot.db ./etcd-snapshot.db
```

A snapshot is a consistent point-in-time copy of the entire keyspace. **This is your only real disaster-recovery artifact.** Back it up on a schedule (a CronJob or the node's cron), store it off-cluster, and test the restore — an untested backup is a hope, not a plan.

### snapshot restore — the dangerous one

Restore writes a *new* data directory from the snapshot. You do **not** restore into a running etcd; you stop etcd, restore to a fresh dir, and point etcd at it.

```bash
docker exec -it dojo-control-plane sh -c '
  ETCDCTL_API=3 etcdctl snapshot restore /var/lib/etcd-snapshot.db \
    --data-dir /var/lib/etcd-restored
'
```

Then, on the node, move `/var/lib/etcd` aside and repoint the etcd static pod's `hostPath` (in `/etc/kubernetes/manifests/etcd.yaml`) at the restored directory. kubelet watches that manifest dir and restarts the static pod automatically. For a multi-node etcd you must restore on every member with matching `--initial-cluster` / `--initial-advertise-peer-urls` flags, or the members won't form a cluster.

> **War story.** A team I know ran a single-node etcd (one control-plane, no HA) and "had backups" — a nightly `snapshot save` that wrote to `/var/lib/etcd-snapshot.db` *on the same disk as etcd*. The disk filled, etcd tripped its `NOSPACE` alarm and went read-only, the node got recycled by the cloud provider's auto-repair, and the snapshot died with the disk. Six months of CRD-defined config — gone. They rebuilt from Git (the one saving grace of GitOps) over three days. Two lessons burned in: **(1)** a backup on the volume you're backing up is not a backup, and **(2)** the moment etcd goes read-only, `kubectl` still *reads* fine, so dashboards look green while every write silently fails. Alert on `etcd_server_has_leader` and the `NOSPACE` alarm, not on "can I curl the API."

### defrag + compaction — why DB SIZE won't shrink

etcd is an MVCC store: every write keeps old revisions until **compaction** discards history, and compaction frees logical space but does not return it to the filesystem until **defrag** rewrites the boltdb file.

```bash
# compact up to the current revision (drops old object versions)
REV=$(docker exec dojo-control-plane sh -c '
  ETCDCTL_API=3 etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint status --write-out="json"' | grep -o '"revision":[0-9]*' | head -1 | cut -d: -f2)

docker exec dojo-control-plane sh -c "
  ETCDCTL_API=3 etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    compact $REV && \
  ETCDCTL_API=3 etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    defrag --command-timeout=60s && \
  ETCDCTL_API=3 etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    alarm disarm
"
```

The API server already auto-compacts every 5 minutes (`--etcd-compaction-interval`), but **defrag is manual and blocking** — it locks the member for the rewrite, so defrag one member at a time, never all at once in an HA cluster. `alarm disarm` is what clears the read-only state after you've freed space below the `--quota-backend-bytes` limit (default 2 GiB, commonly raised to 8 GiB).

---

## Quorum, disk latency, and why etcd is fragile

Raft needs a **majority** of members to agree on every write. That's the quorum table every admin should have memorized:

| etcd members | Majority needed | Failures tolerated |
|:---:|:---:|:---:|
| 1 | 1 | 0 |
| 3 | 2 | 1 |
| 5 | 3 | 2 |
| 7 | 4 | 3 |

Two facts fall out of this table:

- **Always run odd numbers.** A 4-member cluster tolerates the same 1 failure as a 3-member one but has *more* ways to fail — you added cost and risk for nothing.
- **Lose quorum and writes stop cluster-wide.** In a 3-node cluster, two down means no leader can be elected; the API server's writes hang, controllers stall, but reads from the surviving member may still serve stale data. The cluster looks half-alive.

And the thing that silently kills etcd in production: **disk fsync latency.** Every Raft commit must fsync to disk before it's acknowledged. etcd's health threshold is strict:

- `etcd_disk_wal_fsync_duration_seconds` p99 should stay **under ~10 ms**. Spinning disks and noisy-neighbor cloud volumes blow past this.
- `etcd_disk_backend_commit_duration_seconds` p99 should stay **under ~25 ms**.
- `etcd_server_leader_changes_seen_total` climbing = the heartbeat is timing out, usually *because* fsync is slow. Slow disk → missed heartbeats → leader election → write stall → cascading timeouts.

This is why the single most effective etcd tuning is "put it on fast, dedicated SSD/NVMe with no other I/O tenants," and why co-locating a chatty workload on the control-plane node is an outage waiting to happen.

---

## Debugging etcd

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| API writes hang / time out, reads OK | Quorum lost (majority of members down) | Restore a member or restart etcd pods until majority is back; check `endpoint status` IS LEADER |
| `etcdserver: mvcc: database space exceeded` | DB hit `--quota-backend-bytes`; `NOSPACE` alarm → read-only | `compact` → `defrag` → `alarm disarm` |
| `kubectl` slow, apiserver `etcdserver: request timed out` | Slow disk fsync, or defrag running | Check `wal_fsync_duration` p99; move etcd to faster disk; never defrag all members at once |
| Frequent leader changes, RAFT TERM climbing | fsync/network latency causing missed heartbeats | Dedicate the disk; check network between peers; raise `--heartbeat-interval` only as last resort |
| DB SIZE huge but few objects | History not compacted + Events flooding | Verify auto-compaction; cut Event volume; defrag to reclaim file space |
| New control-plane node won't join etcd | Mismatched `--initial-cluster` / wrong peer certs | Fix peer URLs + regenerate peer certs under `/etc/kubernetes/pki/etcd` |

Diagnose each with the exact commands:

```bash
# quorum / leader — the first question in any etcd incident
docker exec dojo-control-plane sh -c '
  ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint status --write-out=table'

# active alarms (NOSPACE / CORRUPT)
docker exec dojo-control-plane sh -c '
  ETCDCTL_API=3 etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    alarm list'

# fsync latency, straight from the etcd pod's /metrics
kubectl -n kube-system exec etcd-dojo-control-plane -- sh -c \
  'wget -qO- --no-check-certificate \
     --certificate=/etc/kubernetes/pki/etcd/server.crt \
     --private-key=/etc/kubernetes/pki/etcd/server.key \
     https://127.0.0.1:2379/metrics' \
  | grep -E 'etcd_disk_(wal_fsync|backend_commit)_duration_seconds_bucket' | tail

# is the apiserver even seeing a leader?
kubectl get --raw /metrics | grep etcd_server_has_leader

# control-plane container crashlooping? look at kubelet + static-pod logs
docker exec dojo-control-plane crictl ps -a | grep etcd
docker exec dojo-control-plane sh -c 'cat /var/log/containers/etcd-*.log | tail -50'
```

> **War story.** During a routine node upgrade, an SRE defragged all three etcd members in a tight `for` loop to "reclaim space before the upgrade." Defrag locks the member it runs on. With member 1 locked, member 2 locked a beat later, and member 3 about to lock, the cluster momentarily had zero members able to vote — quorum collapsed mid-loop, the API server's writes timed out, and the in-flight node drain wedged with half its pods evicted and nowhere to reschedule. The fix was trivial in hindsight: defrag is a *rolling, one-at-a-time* operation with a health check between each member. The real lesson was cultural — they'd never rehearsed etcd maintenance against a staging cluster, so a "safe cleanup" became a Sev-2. Treat etcd maintenance like a deploy: one member at a time, verify `endpoint health` between steps.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Name etcd's *only* client and explain why that makes `:2379` a trust boundary that bypasses RBAC.
2. Pull a Secret's plaintext directly from etcd with `etcdctl get /registry/secrets/...`, and explain what `EncryptionConfiguration` changes — and why existing Secrets stay plaintext until rewritten.
3. Perform a `snapshot save`, copy it off the node, and describe the stop → restore-to-fresh-dir → repoint-static-pod restore flow.
4. Explain why DB SIZE doesn't shrink after deletes, and run `compact` → `defrag` → `alarm disarm` in the right order — one member at a time.
5. Recite the 3/5/7-member quorum-and-tolerance table and explain why even member counts are a mistake.
6. Name the two fsync metrics and their rough thresholds, and explain the slow-disk → leader-flap → write-stall cascade.

➡ Next up: **Extending the API** — once you trust what etcd stores, you'll teach the API server brand-new object kinds with CRDs and operators.
