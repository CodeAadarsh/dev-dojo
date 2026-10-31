# Stateful Identity

Your team migrated a sharded cache from bare pods to a StatefulSet in staging — and immediately hit two bugs. `shard-2` can't reach `shard-0` by hostname because there is no headless Service and no per-pod DNS entries. And when `shard-1` was rescheduled after a node drain it came back with an *empty* volume, because the original spec used a single shared PVC instead of `volumeClaimTemplates`.

Both bugs have the same root cause: treating a stateful workload like a stateless one. Your task is to build the correct object graph from scratch.

## Target state

Namespace: `dojo-sts`. The verifier accepts your solution only when **all** of the following hold:

1. **A StatefulSet** with at least one entry in `spec.volumeClaimTemplates` — so each pod gets its own dedicated PVC, not a shared one.
2. **`spec.serviceName`** on the StatefulSet names a Service that has **`clusterIP: None`** (headless). Without this field, per-pod DNS (`pod-0.svc.ns.svc.cluster.local`) is undefined.
3. **≥ 3 replicas** spec'd, and **≥ 3 readyReplicas** live in the cluster — all pods passing their readiness probe.
4. **3 Bound PVCs** named `data-<sts-name>-0`, `data-<sts-name>-1`, `data-<sts-name>-2` — one per pod, automatically stamped out by Kubernetes from the volumeClaimTemplate named `data`.

## Rules of engagement

- Image: `nginx:1.27-alpine`. Readiness path: `/` on port 80.
- Name the volumeClaimTemplate `data` so PVC names match the pattern above.
- The headless Service `selector` must match the StatefulSet's pod template labels — without this match, `kubectl get endpoints <svc> -n dojo-sts` shows `<none>` and per-pod DNS never resolves.
- Request `1Gi ReadWriteOnce` for each PVC. The `standard` StorageClass (kind default) is fine.
- Create the Service **before** the StatefulSet — `serviceName` should reference an existing object.

When all three pods show `Running` and `READY 1/1`, run the verifier.

## Why this matters

The headless Service is the DNS backbone of every clustered database on Kubernetes. Kafka brokers, Elasticsearch shards, Redis Cluster nodes, Cassandra seeds — they all find each other by stable hostname. Without `clusterIP: None`, you get a round-robin VIP, not a named endpoint per pod. The one field `clusterIP: None` changes DNS from "load balancer" to "one A record per ready pod."

And without `volumeClaimTemplates`, every pod restart is a data wipe. The ordinal suffix (`-0`, `-1`, `-2`) is the stable key that links pod to PVC across reschedules. Lose that link, lose your data.
