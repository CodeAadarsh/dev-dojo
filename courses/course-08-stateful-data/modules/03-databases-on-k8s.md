# Running Databases on Kubernetes

> **Module 03 · Course 08** — The question is not "can you run a database on Kubernetes." You clearly can. The question is "should you, will it stay consistent under pressure, and what breaks first when a node dies without warning." This module covers the full production pattern for running databases well and the failure modes that make experienced operators reach for managed services.

---

## When not to run a database on Kubernetes

Start here — the decision tree matters before you write any YAML.

| Situation | Verdict | Reason |
|-----------|---------|--------|
| Team < 5 engineers, no on-call rotation | Don't | The operational toil — backup, restore, major-version upgrade, incident response, replication monitoring — exceeds the cost of a managed service's monthly bill |
| Cloud provider's managed equivalent exists (RDS, Cloud SQL, Atlas, Aiven) | Probably don't | You get WAL archiving, multi-AZ HA, PITR, read replicas, automated minor patches, and automated failover. Building this on K8s yourself takes months and will be worse for at least a year |
| On-prem or regulated environment where managed SaaS is disallowed | Do | K8s is the right platform here; use an operator (CloudNativePG, Percona, Vitess) rather than raw StatefulSets |
| Dev / staging ephemeral environments | Do | Fast, cheap, in-cluster, data loss is acceptable — these are the best cases |
| Data locality with in-cluster compute matters | Do | Sub-millisecond latency between app and DB; same-cluster eliminates the network hop to an external endpoint |
| You need to run a DB flavor no managed service supports | Do | Niche engines (TimescaleDB, CockroachDB, Dgraph) — community operators exist |

> **Production bar.** If you run a database in production on Kubernetes without: weekly-tested automated backups + restore, a runbook for primary failover, alerting on replication lag, and someone who has actually performed a major-version upgrade on this exact stack in this exact environment — you don't have a production database. You have a database-shaped time bomb.

---

## Single replica vs replicated

The architecture decision is also a risk decision:

| | Single replica | Replicated (primary + N replicas) |
|---|---|---|
| RTO on pod failure | 10–60s (StatefulSet reschedule + startup) | ~5s (client reconnects via proxy/service to a replica) |
| RPO on node failure | Zero if PVC survives; potentially seconds if WAL in OS page cache wasn't flushed | Zero with synchronous replication; seconds with async replication |
| Kubernetes complexity | StatefulSet + PVC + probes + PDB | StatefulSet + headless svc + init-container replication bootstrap + replication user + PDB + operator |
| Right for | Dev/staging, internal tooling, low-RPO-tolerance acceptable | Any production workload with a durability SLA |

For a single-replica database, survival guarantees collapse to: "your data survives if your PVC survives, and the pod's PVC survives if `reclaimPolicy: Retain`." Set `terminationGracePeriodSeconds` long enough for the DB to flush in-flight writes before the pod is killed.

For replicated databases, use an operator. CloudNativePG (Postgres), the Percona Operators (MySQL/MongoDB), and Vitess encode the replication initialization, failover, backup, connection routing, and major-version upgrade logic that would otherwise live in custom init containers you maintain forever.

---

## Probes for databases

HTTP probes don't apply to databases. The right probe per DB type is more nuanced than most guides say.

### PostgreSQL

```yaml
startupProbe:
  exec:
    command: ["pg_isready", "-U", "postgres", "-d", "postgres"]
  failureThreshold: 30   # 30 * 5s = 150s max startup window
  periodSeconds: 5
livenessProbe:
  exec:
    command: ["pg_isready", "-U", "postgres", "-d", "postgres"]
  initialDelaySeconds: 5
  periodSeconds: 10
  failureThreshold: 3
readinessProbe:
  exec:
    command: ["psql", "-U", "postgres", "-c", "SELECT 1"]
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 3
```

`pg_isready` exits 0 only when the server accepts connections at the Postgres protocol level — it's more reliable than `tcpSocket` on port 5432, which passes even when Postgres is in recovery mode and rejecting queries.

The readiness probe uses `SELECT 1` rather than `pg_isready` for a deliberate reason: on a replica, `pg_isready` returns 0 (the server is "ready") even during replication lag. `SELECT 1` will fail if the DB is in hot standby with `hot_standby_feedback` catching up after a primary flush. For a primary: use `SELECT 1`. For a replica you want to exclude from reads during lag: use a custom script that checks `pg_is_in_recovery()` + lag threshold.

### MySQL / MariaDB

```yaml
livenessProbe:
  exec:
    command:
      - sh
      - -c
      - "mysqladmin ping -u root -p${MYSQL_ROOT_PASSWORD}"
  periodSeconds: 10
  failureThreshold: 3
readinessProbe:
  exec:
    command:
      - sh
      - -c
      - "mysql -u root -p${MYSQL_ROOT_PASSWORD} -e 'SELECT 1'"
  periodSeconds: 5
  failureThreshold: 3
```

### The `startupProbe` calculation

Liveness probes fire from pod start. A database that takes 30–120 seconds to initialize (large tablespace, WAL recovery) will be killed and restarted by liveness before it finishes — creating an infinite crash loop. `startupProbe` disables liveness until it either succeeds or exhausts `failureThreshold * periodSeconds`.

Formula:

```
startupProbe.failureThreshold * startupProbe.periodSeconds
  >= max_expected_startup_seconds + margin
```

For a Postgres with up to 90s startup: `failureThreshold: 20`, `periodSeconds: 5` = 100s window. Always add 20% margin.

---

## PodDisruptionBudgets for databases

A PDB is non-negotiable for any replicated database on Kubernetes. Without one, `kubectl drain` (node maintenance, cluster upgrade) can evict all pods simultaneously — the entire cluster goes offline.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: postgres-pdb
  namespace: dojo-postgres
spec:
  minAvailable: 2    # for a 3-node cluster: always keep quorum (2 of 3)
  selector:
    matchLabels:
      app: postgres
```

With `minAvailable: 2`, a drain must wait for a pod to be Running+Ready on the new node before evicting the next one. The drain proceeds pod-by-pod as replacements come up. Total downtime: zero (the cluster keeps quorum throughout).

For a single-replica database, use `minAvailable: 1` as a forcing function: the node cannot be drained without the operator explicitly deleting the PDB first, which forces a conscious decision about downtime rather than a silent eviction during a routine cluster upgrade.

Verify your PDB is actually protecting the StatefulSet:

```bash
kubectl get pdb postgres-pdb -n dojo-postgres
# NAME            MIN AVAILABLE  MAX UNAVAILABLE  ALLOWED DISRUPTIONS  AGE
# postgres-pdb    2              N/A              1                    5d

kubectl describe pdb postgres-pdb -n dojo-postgres
# check that "Selector" matches your pod labels exactly
```

---

## Anti-affinity

Database replicas must not run on the same node. A single node failure taking out both the primary and the only replica is exactly the failure mode you're trying to prevent.

**Hard anti-affinity** (requiredDuringSchedulingIgnoredDuringExecution) — scheduler refuses to co-locate; pod stays `Pending` if the only available node already has a matching pod:

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: postgres
        topologyKey: kubernetes.io/hostname
```

**Soft anti-affinity** (preferredDuringSchedulingIgnoredDuringExecution) — scheduler prefers separate nodes but allows co-location if no alternative exists. Use this in dev clusters with fewer nodes than replicas, where hard anti-affinity would leave pods permanently `Pending`:

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app: postgres
          topologyKey: kubernetes.io/hostname
```

For zone-level HA (don't put primary and replica in the same AZ), use `topology.kubernetes.io/zone` as the `topologyKey`:

```yaml
topologyKey: topology.kubernetes.io/zone
```

> **The "IgnoredDuringExecution" part.** Once scheduled, anti-affinity rules are not continuously enforced. If you add a rule after pods are running, existing pods are not evicted — only newly scheduled pods respect the rule. To rebalance: delete existing pods and let the StatefulSet reschedule them, which now applies the rule.

---

## Resource tuning

Databases are memory-sensitive in ways that most workloads are not. Wrong resource settings are the most common cause of database incidents on Kubernetes.

```yaml
resources:
  requests:
    cpu: 500m        # scheduler placement; set to average observed load
    memory: 1Gi      # must be >= DB's working set (see calculation below)
  limits:
    cpu: 2000m       # allow burst for queries; don't starve under load
    memory: 2Gi      # CRITICAL: must be > request and >= DB memory config
```

**The OOMKill trap.** If `memory.limit < shared_buffers + (max_connections * work_mem) + OS overhead`, the container will be OOMKilled under normal load. Exit code 137 = OOMKill. The calculation for Postgres:

```
memory.limit >= shared_buffers
             + wal_buffers
             + (max_connections * work_mem)
             + ~200 MiB OS/process overhead

Example: shared_buffers=512Mi, work_mem=4Mi, max_connections=100
= 512 + 8 + 100*4 + 200 = 1120 MiB → set limit to 1.5Gi
```

**CPU: set limits generously or omit them.** A CPU-throttled query runs slowly; an OOMKilled pod rolls back transactions, potentially corrupting connections that were mid-transaction. The cost of CPU throttling is latency; the cost of memory pressure is correctness.

Check actual usage before setting requests:

```bash
kubectl top pod -n dojo-postgres --sort-by=memory
# then set requests to 110% of observed average, limits to 150% of observed peak
```

---

## Connection pooling

Direct database connections are expensive:
- Postgres: ~5–10 MiB per backend process
- A `max_connections=100` hard cap means the 101st client gets `FATAL: too many connections`

A connection pooler sits between the app and the database, multiplexing many application connections over few backend connections:

```
App pods (100 instances, each with 1 connection)
    │
    │ 100 connections (cheap — pooler holds them)
    ▼
PgBouncer (1-2 pods, stateless Deployment, no PVC needed)
    │
    │ 10–20 backend connections (Postgres sees only these)
    ▼
Postgres primary (max_connections=50, well within budget)
```

PgBouncer in transaction mode: each app connection is returned to the pool at `COMMIT`/`ROLLBACK`. 100 app pods can share 20 backend connections. The DB's `max_connections` can be set low, reducing per-connection shared memory overhead and improving autovacuum performance.

PgBouncer is a Deployment (stateless) in the same namespace, pointing at the headless FQDN of the primary pod:

```yaml
# in PgBouncer's ConfigMap
[databases]
mydb = host=postgres-0.postgres.dojo-postgres.svc.cluster.local port=5432 dbname=mydb

[pgbouncer]
pool_mode = transaction
max_client_conn = 500
default_pool_size = 20
```

> **Connection pooling does not substitute for a proper PDB.** PgBouncer going down takes all app connections with it. Run 2 replicas of PgBouncer with a standard ClusterIP Service in front — the Service load-balances across them and any pod restart is transparent to clients.

---

## Debugging Databases on Kubernetes

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Pod OOMKilled on heavy load, exit code 137 | `memory.limit` too low for DB's configured working set | `kubectl top pod`; recalculate limit from DB memory config; raise limit |
| Pod restarts in CrashLoopBackOff at startup, exit code 1, no app error | Liveness probe firing before DB finishes initialization | Add `startupProbe` with sufficient `failureThreshold`; read logs for actual startup error |
| After ungraceful node failure, Postgres says "database system was not properly shut down; automatic recovery in progress" | WAL recovery running — this is normal, not corruption | Wait for recovery to complete; do not run `pg_resetwal`; monitor logs for "database system is ready to accept connections" |
| Two database pods both accept writes (split-brain) | Readiness probe passes on replica even when it thinks it's primary | Add primary/replica check to readiness probe; use an operator that manages fencing; inspect `pg_is_in_recovery()` on each pod |
| Queries dramatically slower after pod reschedule to new node | Pod moved to a node with spinning disk or remote NFS; PVC provisioned with `Immediate` binding | `kubectl describe pod` → node name; `kubectl get pv` → nodeAffinity; switch StorageClass to `WaitForFirstConsumer` |
| `kubectl drain` hangs indefinitely | PDB with `minAvailable: 1` blocking eviction while the DB is the only pod Running (no replicas) | Scale up a replica and confirm it's Ready; or delete the PDB to force downtime (intentional decision) |
| Postgres refuses to start: "could not lock file postmaster.pid: No such file or directory" or "lock file postmaster.pid already exists" | `postmaster.pid` left behind by ungraceful kill | `kubectl exec` → `rm /var/lib/postgresql/data/postmaster.pid`; then delete + reschedule the pod |

### Exact commands for each

**OOMKill diagnosis:**

```bash
kubectl get pod postgres-0 -n dojo-postgres \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
# -> OOMKilled

kubectl top pod -n dojo-postgres --sort-by=memory

kubectl -n dojo-postgres exec postgres-0 -- \
  psql -U postgres -c "SHOW shared_buffers; SHOW work_mem; SHOW max_connections;"
# compare these values against your memory.limit
```

**Split-brain check:**

```bash
# pg_is_in_recovery() returns 'f' on a PRIMARY, 't' on a REPLICA
kubectl exec -n dojo-postgres postgres-0 -- \
  psql -U postgres -c "SELECT pg_is_in_recovery();"

kubectl exec -n dojo-postgres postgres-1 -- \
  psql -U postgres -c "SELECT pg_is_in_recovery();"

# both returning 'f' = split-brain; exactly one should return 'f'
# if split-brain: promote only one, fence the other (delete the pod or set it read-only)
```

**Slow disk — find what storage the pod actually got:**

```bash
# which PVC and PV?
PVC=$(kubectl get pod postgres-0 -n dojo-postgres \
  -o jsonpath='{.spec.volumes[0].persistentVolumeClaim.claimName}')
PV=$(kubectl get pvc "$PVC" -n dojo-postgres \
  -o jsonpath='{.spec.volumeName}')
kubectl get pv "$PV" -o jsonpath='{.spec.nodeAffinity}{"\n"}'

# benchmark disk throughput from inside the pod (delete the test file after)
kubectl exec -n dojo-postgres postgres-0 -- \
  sh -c "dd if=/dev/zero of=/var/lib/postgresql/data/iobench bs=1M count=100 oflag=direct conv=fdatasync 2>&1; rm /var/lib/postgresql/data/iobench"
# < 50 MB/s = spinning disk or remote NFS; a local SSD should be > 200 MB/s
```

**postmaster.pid stuck after ungraceful kill:**

```bash
kubectl exec -n dojo-postgres postgres-0 -- \
  ls -la /var/lib/postgresql/data/postmaster.pid

# if it exists and the process is dead:
kubectl exec -n dojo-postgres postgres-0 -- \
  rm /var/lib/postgresql/data/postmaster.pid

kubectl delete pod postgres-0 -n dojo-postgres
# StatefulSet restarts it; PID file is gone; clean startup
```

> **War story.** At SAP, we ran a PostgreSQL 14 single-replica StatefulSet for a low-traffic internal audit service. One Friday evening a GKE node hit a kernel panic and was forcibly rescheduled. The pod came back, the liveness probe passed (`pg_isready` returned 0), but every `SELECT` returned `ERROR: could not read block 0 in file "base/16384/1259"` — a corrupted system catalog page. We hadn't lost the PVC; the PV was intact. The corruption came from how we'd set `memory.limit: 512Mi` against a Postgres with `shared_buffers=256MB`. At the moment of the kernel panic, the Linux page cache held dirty Postgres shared buffer pages that hadn't been flushed to the PVC. The node died without calling `sync`. The OS page cache vanished. The PVC had stale data that Postgres's WAL expected to be newer. The fix was `terminationGracePeriodSeconds: 60` — giving Postgres time to run a checkpoint on `SIGTERM` before the pod is hard-killed — and raising `memory.limit` to `1.5Gi` to reflect actual working set. The rule: **`terminationGracePeriodSeconds` must be >= your DB's effective checkpoint interval.** For Postgres with default `checkpoint_timeout=5min` and `checkpoint_completion_target=0.9`, a graceful shutdown triggers a final checkpoint — budget 60–120s. Without it, every hard-kill is a potential corrupt-on-recovery event.

---

## Checkpoint

1. State two situations where you would run a database on Kubernetes and two where you'd use a managed service — and articulate the deciding factor for each.
2. Explain why `startupProbe` is required for slow-starting databases, and calculate the correct `failureThreshold` for a database with up to 90s startup using `periodSeconds: 5`.
3. Write a `PodDisruptionBudget` for a 3-replica Postgres cluster that ensures quorum is never lost.
4. Explain the difference between hard and soft pod anti-affinity and describe a cluster condition where hard anti-affinity causes a pod to stay `Pending`.
5. Calculate the minimum `memory.limit` for a Postgres with `shared_buffers=512Mi`, `work_mem=8Mi`, `max_connections=50`.
6. Describe where PgBouncer sits in the request path and explain what `pool_mode = transaction` means for connection lifetime.
7. Explain why `terminationGracePeriodSeconds` is critical for databases and how to calculate the right value for your Postgres configuration.
8. From first principles, use only `kubectl exec` + `psql` to determine which pod in a two-pod StatefulSet is the primary.
