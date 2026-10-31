# StatefulSets & Stable Identity

> **Module 01 · Course 08** — A Deployment treats every pod as fungible: lose one, get another, same behavior. A StatefulSet says "no, pod-0 is pod-0 forever." That seemingly small contract — stable name, stable storage, stable order — is the entire difference between "I can run postgres" and "I cannot run postgres." This module covers what that contract actually means and exactly where it breaks.

You already reach for Deployments reflexively. The question isn't "what is a StatefulSet" — it's "when does the fungibility assumption break and what exactly changes when it does."

---

## Why fungibility breaks for stateful workloads

Deployments assume every replica is equivalent: any pod can serve any request, any pod can die without data loss, and there is no meaningful distinction between replica-0 and replica-3. That assumption is exactly right for stateless services.

The moment you add local state, the fungibility assumption breaks in at least one of three ways:

1. **Data affinity** — pod-0's data lives on a specific volume; a replacement pod must mount *that same volume*, not a fresh empty one.
2. **Network identity** — a Kafka broker must announce itself as `broker-0` consistently so other brokers and clients can find it by name. DNS round-robins won't do; you need to reach a *specific* pod by a stable hostname.
3. **Init ordering** — a cluster database initializes its leader before replicas are allowed to start. If pods can start in any order you get split-brain.

StatefulSets were built to enforce exactly these three constraints.

---

## StatefulSets vs Deployments — the actual diff

| What | Deployment | StatefulSet |
|------|-----------|-------------|
| Pod name | random suffix (`web-7f9d5b-abc`) | deterministic ordinal (`web-0`, `web-1`) |
| In-container hostname | same random suffix | `web-0`, `web-1` |
| Individual pod DNS | not addressable | `web-0.web.ns.svc.cluster.local` (requires headless svc) |
| Storage | optional shared PVC, or none | one PVC per pod from `volumeClaimTemplates`, named `data-web-0` |
| Scale-up order | parallel | 0 → 1 → 2 (each must be Running+Ready before next starts) |
| Scale-down order | parallel | 2 → 1 → 0 (reverse ordinal) |
| Rolling update order | parallel (bounded by `maxUnavailable`) | N-1 → N-2 → ... → 0 (one at a time by default) |
| `kubectl rollout undo` | supported | supported, same reverse-ordinal order |

The spec field that drives the entire ordinal contract is `serviceName` — a StatefulSet requires a headless Service by that name to exist, and each pod registers itself under `<pod>.<serviceName>.<ns>.svc.cluster.local`.

---

## Headless Services — the DNS backbone

StatefulSet pods get individual DNS entries only when backed by a **headless Service**: `clusterIP: None`. A normal Service with a VIP does round-robin; a headless Service creates one A record per Ready endpoint.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: dojo-stateful
spec:
  clusterIP: None          # headless — no VIP, one A record per pod endpoint
  selector:
    app: web
  ports:
    - port: 80
      name: http
```

With this in place, from anywhere in the cluster:

```bash
# creates a throwaway pod to test DNS — remove --restart=Never for a persistent shell
kubectl run -n dojo-stateful dns-test --rm -it --image=busybox:1.36 \
  --restart=Never -- nslookup web.dojo-stateful.svc.cluster.local
# returns multiple A records, one per Ready pod

kubectl run -n dojo-stateful dns-test2 --rm -it --image=busybox:1.36 \
  --restart=Never -- nslookup web-0.web.dojo-stateful.svc.cluster.local
# returns exactly one A record — the IP of pod web-0
```

The per-pod FQDN is: `<pod-name>.<service-name>.<namespace>.svc.cluster.local`

This is how a database replica registers with the primary. It's how a client reads from a specific shard. Without the headless Service, per-pod DNS is undefined and the StatefulSet is half-broken — pods get ordinal names but no resolvable addresses.

> **Selector must match exactly.** If the headless Service's `selector` doesn't match the pod's labels, `kubectl get endpoints web -n dojo-stateful` shows `<none>`. The pod still starts (it's a separate object), but DNS entries are never created. This is the most common StatefulSet DNS bug and it shows up as "NXDOMAIN" from the app.

---

## volumeClaimTemplates — per-pod PVCs

A StatefulSet doesn't mount a single shared PVC. It stamps out one PVC per pod from the `volumeClaimTemplates` section, naming each `<template-name>-<pod-name>`.

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: web
  namespace: dojo-stateful
spec:
  serviceName: "web"       # must match the headless Service name above
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: data
              mountPath: /usr/share/nginx/html
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: standard
        resources:
          requests:
            storage: 1Gi
```

This creates three PVCs automatically:

```
data-web-0  →  pod web-0  →  mounts at /usr/share/nginx/html
data-web-1  →  pod web-1  →  mounts at /usr/share/nginx/html
data-web-2  →  pod web-2  →  mounts at /usr/share/nginx/html
```

When `web-1` is killed and rescheduled (node failure, restart, update), the new pod-1 **mounts `data-web-1`** — same PVC, same data. The ordinal is the stable key that connects pod to persistent state.

Inspect them:

```bash
kubectl get pvc -n dojo-stateful
# NAME        STATUS  VOLUME           CAPACITY  ACCESS MODES  STORAGECLASS
# data-web-0  Bound   pvc-abc...       1Gi       RWO           standard
# data-web-1  Bound   pvc-def...       1Gi       RWO           standard
# data-web-2  Bound   pvc-ghi...       1Gi       RWO           standard

kubectl get pvc data-web-0 -n dojo-stateful \
  -o jsonpath='{.spec.volumeName}{"\n"}'
# pvc-abc123...
```

> **PVC lifetime caveat.** When you `kubectl scale sts web --replicas=1`, pods 1 and 2 are deleted — but **their PVCs are not**. This is intentional: accidentally destroying data is worse than leaking storage. You must manually delete `data-web-1` and `data-web-2` if you actually want to reclaim the space. Scale back up to 3 and the same PVCs reattach. This surprises almost everyone the first time.

---

## Ordered rollout and partitioned updates

**Scale-up** is strictly gated: pod `N` doesn't start until pod `N-1` is Running **and** Ready (readiness probe passing). This matters for quorum databases where a cluster of 1 must be stable before node 2 joins — out-of-order starts cause split-brain.

**Rolling updates** go in reverse: pod `N-1` is updated first, down to pod `0`. Same gate — each pod must be Running+Ready before the next update proceeds.

Watch an update in real time:

```bash
kubectl -n dojo-stateful rollout status sts/web
# Waiting for partitioned roll out to finish: 2 out of 3 new pods have been updated...

kubectl -n dojo-stateful get pods -w
# web-2   Terminating
# web-2   Pending
# web-2   Running  (then Ready, then web-1 starts)
```

**Partitioned updates** let you canary a new image on one replica before rolling to the rest. Set `updateStrategy.rollingUpdate.partition: N` — pods with ordinal >= N get the new template; pods below N are untouched, even if you `kubectl rollout restart`.

```yaml
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    partition: 2   # only web-2 gets the new image; web-0 and web-1 stay unchanged
```

Apply a new image and watch only web-2 update:

```bash
kubectl set image sts/web web=nginx:1.27 -n dojo-stateful
# web-2 updates; web-0 and web-1 stay on the old image

# verify the canary, then clear the partition to roll out the rest
kubectl patch sts web -n dojo-stateful \
  -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":0}}}}'
```

This is how you test a new Postgres version on one replica before promoting it, or validate a new config on one cache shard before rolling cluster-wide.

---

## Debugging StatefulSets

Stuck ordinals, headless DNS failures, and PVC lifecycle surprises cover 90% of StatefulSet incidents.

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `web-1` stuck `Pending` forever; `web-2` never starts | Readiness probe failing on `web-1` — gate never opens | `kubectl describe pod web-1 -n <ns>` → Events; fix probe or app health |
| `web-1` stuck `ContainerCreating`, `web-0` is fine | PVC `data-web-1` is `Pending` (no matching PV, wrong StorageClass, provisioner down) | `kubectl get pvc -n <ns>` → `kubectl describe pvc data-web-1 -n <ns>` → Events |
| Headless DNS returns NXDOMAIN for `web-0.web.ns.svc.cluster.local` | `serviceName` in StatefulSet doesn't match headless Service name, OR Service `selector` doesn't match pod labels | `kubectl get endpoints web -n <ns>` — must be non-empty; `kubectl get svc web -n <ns> -o jsonpath='{.spec.clusterIP}'` — must be `None` |
| After `kubectl scale sts web --replicas=1`, old PVCs still exist and storage bill grows | Expected behavior — StatefulSets never auto-delete PVCs on scale-down | Delete manually: `kubectl delete pvc data-web-1 data-web-2 -n <ns>` |
| `kubectl rollout restart sts/web` only updates web-2 | `partition` is set >= 1 | `kubectl get sts web -n <ns> -o jsonpath='{.spec.updateStrategy.rollingUpdate.partition}'` → set to 0 |
| Pod stuck `Terminating` for minutes during scale-down | Finalizer on PVC or pre-stop hook taking longer than `terminationGracePeriodSeconds` | `kubectl describe pod web-2 -n <ns>` → finalizer list; last resort: `kubectl delete pod web-2 -n <ns> --force --grace-period=0` |

### Exact commands for each

**Stuck ordinal — check the gate:**

```bash
# what's blocking web-1?
kubectl -n dojo-stateful describe pod web-1 | grep -A20 'Conditions:\|Events:'
# look for: Readiness probe failed, Unschedulable, Init:Error

# ContainersReady=False is the literal gate condition
kubectl -n dojo-stateful get pod web-1 \
  -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{"\n"}{end}'

# is the app actually failing the probe?
kubectl -n dojo-stateful logs web-1
kubectl -n dojo-stateful logs web-1 --previous   # if it's been restarting
```

**PVC not deleted on scale-down:**

```bash
# see dangling PVCs after scaling to 1
kubectl -n dojo-stateful get pvc -l app=web
# data-web-0  Bound
# data-web-1  Bound  ← still exists after web-1 was deleted
# data-web-2  Bound  ← still exists after web-2 was deleted

# scale back up — PVCs reattach; no data loss
kubectl scale sts web -n dojo-stateful --replicas=3

# or permanently clean up
kubectl delete pvc data-web-1 data-web-2 -n dojo-stateful
```

**Headless DNS debugging:**

```bash
# is the service headless?
kubectl -n dojo-stateful get svc web -o jsonpath='{.spec.clusterIP}{"\n"}'
# must print "None"; anything else is a regular Service

# does the service selector match the pod labels?
kubectl -n dojo-stateful get endpoints web
# Endpoints: 10.244.x.x:80,10.244.y.y:80,10.244.z.z:80  ← healthy
# Endpoints: <none>  ← selector mismatch

# test resolution from inside the cluster
kubectl run -n dojo-stateful dns-debug --rm -it --image=busybox:1.36 \
  --restart=Never -- sh -c \
  "nslookup web-0.web.dojo-stateful.svc.cluster.local && nslookup web.dojo-stateful.svc.cluster.local"
```

> **War story.** We ran a three-node Redis Cluster StatefulSet at SAP. After a cluster upgrade that rolled the worker nodes, `redis-1` came back Running but stuck in `CLUSTER INFO` state `fail` — it couldn't rejoin the ring. The issue: the headless Service selector used `app: redis` but the pod template had been patched six weeks earlier to `app: redis-cluster`. After the upgrade, the new `redis-1` pod had the updated label but the old Service still had `app: redis`. The selector stopped matching, so `redis-1.redis.prod.svc.cluster.local` stopped resolving. `redis-0` and `redis-2` assumed `redis-1` was gone and orphaned its hash slots. `kubectl get endpoints redis -n prod` showed `Endpoints: <none>` — one command that would have saved two hours of incident response. Check endpoints before you check anything else.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. State the three stability guarantees a StatefulSet makes that a Deployment does not.
2. Create a headless Service for a StatefulSet named `db` in namespace `dojo-pg` and explain why `clusterIP: None` changes DNS behavior.
3. Predict the name of the PVC created from `volumeClaimTemplates[0].metadata.name: logs` for pod `redis-2`.
4. Walk through what happens step by step when you scale a 3-replica StatefulSet from 3→1 (pod deletion order, PVC fate).
5. Use `kubectl get sts -o jsonpath` to read the `partition` value of a running StatefulSet.
6. Diagnose a stuck ordinal from first principles: what two resources do you inspect first?
7. Explain the `partition` update strategy and name a real production scenario where you'd use it.
8. Run the command that proves a headless Service is actually headless and has the right endpoints.

➡ Next up: **Storage: CSI, PV, PVC & StorageClasses** — the binding chain that actually backs those `volumeClaimTemplates`.
