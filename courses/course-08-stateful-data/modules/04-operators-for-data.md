# The Operator Pattern for Data

> **Module 04 · Course 08** — A StatefulSet manages Pod identity and ordered rollouts. It has no idea what a Postgres primary is, what a Kafka ISR is, or when it's safe to restart a broker. That gap is what operators fill. This module dissects the operator pattern from first principles and shows you three production-grade implementations.

The core observation is brutally simple: **a database isn't a Deployment.** It has state, topology (primary/replica, controller/broker), ordered startup/shutdown semantics, and a set of day-2 operations — failover, backup, resize, major-version upgrade — that a human DBA would execute by hand following a runbook. An operator encodes that runbook into a controller loop.

---

## Why Stateful Systems Need Operators

Consider what it takes to run a highly-available PostgreSQL cluster manually on Kubernetes:

```
Week 1:  Deploy primary + 2 replicas via StatefulSet. Streaming replication working.
Week 3:  Primary node drains for patching. You SSH in, manually failover replica to primary.
Week 5:  A replica falls too far behind WAL. You pg_basebackup it from scratch.
Week 6:  Backup job fails silently. You find out during a restore test.
Month 3: Postgres 15 → 16 upgrade. Three hours of pg_upgrade, replica rebuild, rollback plan.
```

An operator makes every one of those operations a one-line `kubectl patch` or a field change in a CR. More importantly, it *detects* the failure and acts without a human waking up at 3am.

The three operators worth knowing deeply — because they cover the full landscape of stateful data:

| Operator | Manages | Production adoption |
|----------|---------|---------------------|
| **CloudNativePG** | PostgreSQL | Zalando-lineage, CNCF sandbox, heavy Postgres-specific support |
| **Zalando Postgres Operator** | PostgreSQL | Older but widely deployed in enterprise clusters |
| **Strimzi** | Apache Kafka | The de facto standard for Kafka on K8s; CNCF incubating |

---

## CRDs: Encoding Ops Knowledge into the API

Every operator ships one or more **Custom Resource Definitions** that extend the Kubernetes API. The CRD is the boundary between "what you want" (the spec) and "what the operator knows how to do" (the controller). Think of it as a type-safe runbook.

A CloudNativePG cluster resource looks like this:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-main
  namespace: dojo-data
spec:
  instances: 3                          # 1 primary + 2 replicas
  imageName: ghcr.io/cloudnative-pg/postgresql:16.3
  storage:
    size: 10Gi
    storageClass: standard
  postgresql:
    parameters:
      max_connections: "200"
      shared_buffers: "256MB"
  backup:
    retentionPolicy: "30d"
    barmanObjectStore:
      destinationPath: s3://my-bucket/pg-main
      s3Credentials:
        accessKeyId:
          name: pg-backup-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: pg-backup-creds
          key: SECRET_ACCESS_KEY
```

What's embedded in that 30-line YAML:
- Knowledge that 3 instances means 1 primary + 2 standbys, not 3 independent Postgres
- Knowledge to configure `pg_hba.conf` for streaming replication automatically
- Knowledge that `storage.size` maps to a PVC per pod, not a shared volume
- Knowledge that backup should use Barman and how to authenticate to S3
- Knowledge that `max_connections` is a GUC, not a container env var

The Zalando operator uses a similar `postgresql` CRD. Strimzi's top-level type is `Kafka`:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: events-cluster
  namespace: dojo-streaming
spec:
  kafka:
    version: 3.7.0
    replicas: 3
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
    config:
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      default.replication.factor: 3
      min.insync.replicas: 2
    storage:
      type: jbod
      volumes:
        - id: 0
          type: persistent-claim
          size: 50Gi
          deleteClaim: false
  zookeeper:
    replicas: 3
    storage:
      type: persistent-claim
      size: 10Gi
      deleteClaim: false
  entityOperator:
    topicOperator: {}
    userOperator: {}
```

Strimzi's `Kafka` CR encodes knowledge that `min.insync.replicas: 2` with `replicas: 3` is a sensible consistency choice, that ZooKeeper (or KRaft in newer versions) needs its own stable storage, and that `deleteClaim: false` means "don't wipe data when I delete the CR" — an intentional safety default.

---

## The Reconcile Loop

Every operator is a **controller** — a tight loop that:

1. Watches one or more resource types (usually its own CRs + Pods/PVCs/Services/etc.)
2. Computes the delta between *desired state* (the spec) and *observed state* (the cluster)
3. Acts to close the gap
4. Re-enqueues on any relevant event, or after a timeout

```
┌─────────────────────────────── operator process ───────────────────────────────┐
│                                                                                 │
│   ┌─────────────┐    Watch/Informer     ┌──────────────┐                       │
│   │  Kubernetes │ ──────────────────>   │  Work Queue  │                       │
│   │  API server │ <──────────────────   │  (key: ns/   │                       │
│   │             │    CRUD on owned       │   name)      │                       │
│   │  Cluster{} │    child resources    └──────┬───────┘                       │
│   │  Kafka{}   │                              │                                │
│   │  Pods, PVCs│                        ┌─────▼──────────────────────────┐    │
│   │  Services  │                        │   Reconcile(ctx, req)          │    │
│   └─────────────┘                       │                                │    │
│                                         │  1. Fetch desired (CR spec)    │    │
│                                         │  2. Fetch observed (children)  │    │
│                                         │  3. Diff                       │    │
│                                         │  4. Act (create/patch/delete)  │    │
│                                         │  5. Update CR status           │    │
│                                         └────────────────────────────────┘    │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

The reconcile loop is **level-triggered, not edge-triggered.** It doesn't try to remember transitions ("I saw a pod die"). It reads the full current state each iteration. This makes operators resilient to missed events — if the operator crashes and restarts, it reconciles from scratch and converges correctly.

**Idempotency is mandatory.** The same reconcile call should be safe to run 100 times. This is why operators use `CreateOrUpdate` patterns and never accumulate side effects.

---

## Day-2 Operations: Automated by the Operator

The real payoff of the operator pattern is day-2 ops. Here's what the three operators handle without manual intervention:

### Automated Failover

When CloudNativePG detects a primary Pod is unresponsive (via health checks + a fencing mechanism), it:
1. Fences the old primary (prevents split-brain writes)
2. Promotes the most-advanced replica to primary
3. Updates the `rw` Service to point at the new primary
4. Re-creates the old primary as a replica once the node recovers

Watch it happen:

```bash
# force-delete the primary pod — simulates a node failure
PRIMARY=$(kubectl -n dojo-data get cluster pg-main \
  -o jsonpath='{.status.currentPrimary}')
kubectl -n dojo-data delete pod "$PRIMARY" --force --grace-period=0

# watch the operator promote a new primary in the status
kubectl -n dojo-data get cluster pg-main -w \
  -o custom-columns='PHASE:.status.phase,PRIMARY:.status.currentPrimary,READY:.status.readyInstances'
```

### Backup Scheduling

CloudNativePG can schedule continuous WAL archiving + periodic base backups:

```yaml
spec:
  backup:
    retentionPolicy: "30d"
    barmanObjectStore:
      destinationPath: s3://my-bucket/pg-main
      wal:
        compression: gzip
        maxParallel: 2
```

The operator creates a `ScheduledBackup` resource and watches backup completion, surfacing results in `.status`. You don't run a CronJob; the operator owns the backup lifecycle.

### Topology-Aware Restarts

Strimzi rolling-updates brokers in the right order — draining partitions off a broker before restarting it, so in-sync replicas never drop below `min.insync.replicas`. A plain `kubectl rollout restart` would not know to do this and could cause producer errors.

```bash
# correct way to restart a Strimzi cluster: annotate, let the operator sequence it
kubectl -n dojo-streaming annotate kafka events-cluster \
  strimzi.io/manual-rolling-update=true
```

### Resize and Version Upgrades

For CloudNativePG, a minor version upgrade is a spec edit:

```bash
kubectl -n dojo-data patch cluster pg-main --type=merge \
  -p '{"spec":{"imageName":"ghcr.io/cloudnative-pg/postgresql:16.4"}}'
```

The operator rolls replicas first (verifying replication lag), then failovers to a new primary, then rolls the old primary. No manual `pg_upgrade`. No runbook pages.

---

## Examining Operator Status

Operators update the `.status` subresource of CRs. Always read status first when something looks wrong:

```bash
# CloudNativePG cluster health at a glance
kubectl -n dojo-data get cluster pg-main
# NAME      AGE   INSTANCES   READY   STATUS   PRIMARY
# pg-main   2d    3           3       Cluster in healthy state   pg-main-1

# full status including conditions
kubectl -n dojo-data get cluster pg-main -o jsonpath='{.status.conditions}' \
  | tr ',' '\n'

# Strimzi: check Kafka readiness
kubectl -n dojo-streaming get kafka events-cluster \
  -o jsonpath='{.status.conditions[*].type}{"\n"}{.status.conditions[*].status}'
```

Conditions follow the standard Kubernetes pattern — `Ready`, `Progressing`, with `reason` and `message` fields telling you exactly what the operator is waiting on.

---

## Finalizers: Why CRs Sometimes Refuse to Delete

Operators use **finalizers** to ensure they can clean up their own resources before a CR is garbage-collected. A finalizer is just a string in `metadata.finalizers`; the API server blocks deletion until all finalizers are removed.

```bash
# inspect finalizers on a CloudNativePG cluster
kubectl -n dojo-data get cluster pg-main -o jsonpath='{.metadata.finalizers}'
# ["postgresql.cnpg.io/cluster"]

# inspect finalizers on a PVC (storage operator may own this too)
kubectl -n dojo-data get pvc pgdata-pg-main-1 \
  -o jsonpath='{.metadata.finalizers}'
```

Normal scenario: you `kubectl delete cluster pg-main`, the operator removes child resources, then removes its finalizer, and the CR disappears. Stuck scenario: the operator is down (crashed, uninstalled) or encounters an error during cleanup — the CR sits in `Terminating` forever because nothing is removing the finalizer.

The nuclear option (use only when the operator is gone and you've verified children are cleaned up manually):

```bash
kubectl -n dojo-data patch cluster pg-main \
  --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
```

Do not do this if the operator is running — you'll leave orphaned PVCs and Services that the operator will never clean up.

---

## Debugging Operators

### Debugging: Operator Stuck Reconciling

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| CR stuck in `Progressing` for >10 min | Operator erroring in reconcile loop — check its logs | `kubectl -n <operator-ns> logs deploy/<operator> --since=10m \| grep -i error` |
| Pod for a CR instance never created | RBAC gap — operator's ServiceAccount missing a verb on a resource type | Check operator logs for `Forbidden`; patch the ClusterRole |
| CR status shows no conditions at all | Operator not running / not watching the right namespace | `kubectl -n <operator-ns> get pods`; check CRD `spec.scope` (Cluster vs Namespaced) |
| `kubectl describe` on CR shows no events | Operator uses status conditions only, not Events; or operator is not installed | Check `kubectl get crd \| grep <domain>` — if the CRD is missing, the operator was never installed |
| Reconcile storms — operator logging hundreds of lines per second | A watched child resource (Pod, PVC) is flapping | Find the flapping resource; the operator is healthy but reacting to noise |

```bash
# read the operator's logs, filtering to the CR you care about
kubectl -n cnpg-system logs deploy/cnpg-controller-manager --since=5m \
  | grep pg-main

# check the operator's own health
kubectl -n cnpg-system get deploy cnpg-controller-manager \
  -o jsonpath='{.status.conditions[*].type}:{.status.conditions[*].status}'

# list CRDs owned by the operator
kubectl get crd | grep cnpg.io

# get a short summary of all CR instances and their phase
kubectl get clusters.postgresql.cnpg.io -A
```

### Debugging: CR Validation Errors

If your CR spec violates the CRD's OpenAPI schema, the API server rejects it immediately:

```
Error from server (Invalid): error when creating "cluster.yaml":
  Cluster.postgresql.cnpg.io "pg-main" is invalid:
  spec.storage.size: Invalid value: "": must be a valid quantity
```

These are schema validation errors — the operator never sees the object. Fix:

```bash
# dry-run to validate before applying
kubectl apply -f cluster.yaml --dry-run=server

# check the CRD schema to see what's required
kubectl explain cluster.spec.storage --api-version=postgresql.cnpg.io/v1

# if you're getting unexpected rejections, check for admission webhooks
kubectl get validatingwebhookconfigurations | grep cnpg
kubectl get mutatingwebhookconfigurations | grep cnpg
```

Admission webhooks are common in operator installs. If the webhook's Pod is down, the API call fails — even for valid objects. Check the webhook's caBundle is current and its Service endpoint is reachable.

### Debugging: Finalizers Blocking Deletion

```bash
# see that a CR or PVC is stuck Terminating
kubectl -n dojo-data get cluster pg-main
# NAME      ...  PHASE        TERMINATING
# pg-main        Terminating  <timestamp>

# confirm there's a finalizer blocking it
kubectl -n dojo-data get cluster pg-main \
  -o jsonpath='{.metadata.finalizers}{"\n"}'

# check whether the operator is running and healthy
kubectl -n cnpg-system get pods
kubectl -n cnpg-system logs deploy/cnpg-controller-manager --tail=50

# if operator is healthy but stuck: look for a stuck child that the operator
# is waiting to delete before removing its finalizer
kubectl -n dojo-data get pvc,pods,svc -l "postgresql=pg-main"
```

> **War story.** We ran CloudNativePG in a staging environment and someone `helm uninstall`ed the operator to "clean up" without first deleting the Cluster CR. The CRDs were gone (Helm deleted them), so the API server no longer knew about `Cluster` objects — but the Cluster CR was still in etcd with its finalizer, just unreadable. Every `kubectl get cluster` returned "the server could not find the requested resource." The only way out was to re-install CloudNativePG, re-register the CRDs, at which point the operator picked up the orphaned CR and completed its deletion. Lesson: always `kubectl delete` your CRs before `helm uninstall`ing the operator that owns them. Make that order a written step in your runbook.

---

## Checkpoint

You're solid on this module when you can answer without looking anything up:

1. State in one sentence why a StatefulSet alone is insufficient for running a database in production.
2. Name the three operators covered here and what each manages.
3. Explain what a reconcile loop does and why level-triggered beats edge-triggered for operator reliability.
4. Walk through what CloudNativePG does automatically when the primary Pod is force-deleted.
5. Look at a CR's `.status.conditions` and tell whether it's healthy or stuck.
6. Explain what a finalizer is and the correct sequence for removing a CR whose operator has been uninstalled.
7. Diagnose a CR that has been `kubectl delete`d but sits in `Terminating` for 20 minutes.
8. Explain why `kubectl annotate kafka strimzi.io/manual-rolling-update=true` is safer than `kubectl rollout restart` for Kafka.

➡ Next up: **Backup & Restore** — because an operator can automate backups, but someone still has to prove they work.
