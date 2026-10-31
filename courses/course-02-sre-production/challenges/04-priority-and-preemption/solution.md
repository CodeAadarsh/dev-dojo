# Solution — Who Gets Evicted First

Two objects: a cluster-scoped `PriorityClass`, and a one-field patch to the `payments` pod template that references it. The flag is `KUBE{priority_decides_eviction_order}`.

## 1. Create the PriorityClass

`PriorityClass` is **cluster-scoped** — no namespace.

```yaml
# dojo-critical-priority.yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: dojo-critical
value: 1000000                 # well above 0, well below the system-* band
globalDefault: false           # do NOT make this the default for every unlabeled pod
preemptionPolicy: PreemptLowerPriority   # the default; spelled out for intent
description: "Revenue-critical workloads. Preempts lower-priority tenants when nodes are full."
```

```bash
kubectl apply -f dojo-critical-priority.yaml
kubectl get priorityclass dojo-critical -o custom-columns=NAME:.metadata.name,VALUE:.value,DEFAULT:.globalDefault
```

Two fields earn their keep:

- **`globalDefault: false`** — if you ever set `true`, *every* pod created without an explicit `priorityClassName` silently inherits this value. You almost never want that; it defeats the ranking. There can be at most one global default in the cluster.
- **`preemptionPolicy: PreemptLowerPriority`** (the default) means a pending pod of this class *will* evict lower-priority pods to get scheduled. Set it to **`Never`** for a high-priority-but-polite workload that should jump the scheduling *queue* but not forcibly evict anyone (common for important-but-not-urgent batch work).

## 2. Bind the Deployment to it

Priority is a pod-template field, so set it under `spec.template.spec`, not on the Deployment itself:

```bash
kubectl -n dojo-priority patch deploy payments --type merge \
  -p '{"spec":{"template":{"spec":{"priorityClassName":"dojo-critical"}}}}'

kubectl -n dojo-priority rollout status deploy/payments
```

Or declaratively, the relevant slice of the manifest:

```yaml
spec:
  template:
    spec:
      priorityClassName: dojo-critical    # admission stamps spec.priority: 1000000
      containers:
        - name: payments
          image: nginx:1.27-alpine
```

Confirm the integer actually landed on the pods — this is what the scheduler and kubelet read:

```bash
kubectl -n dojo-priority get pods -l app=payments \
  -o custom-columns=POD:.metadata.name,PRIORITY:.spec.priority,CLASS:.spec.priorityClassName
# PRIORITY should read 1000000 on every payments pod; batch pods stay at <none>/0
```

Then run the verifier:

```bash
bash courses/course-02-sre-production/challenges/04-priority-and-preemption/verify.sh
```

## Why each piece is correct

- **The integer, not the name, is what the scheduler compares.** The name is a convenient handle; admission resolves it to `spec.priority` once, at pod-creation time. Editing a PriorityClass's `value` later does **not** retro-update existing pods — they keep the integer they were stamped with. To re-rank running pods you must recreate them (a rollout).
- **`value: 1000000`** is high enough to dominate every priority-0 tenant on the node, yet an order of magnitude below `system-cluster-critical` (2000000000), so you can never preempt CoreDNS or the CNI. That headroom is deliberate.
- **Template-level field.** Putting `priorityClassName` on the pod template (not a bare pod) means every replica — current and future rollouts — inherits it. A Deployment with the field unset leaves pods at priority 0.

## Watch preemption happen (optional, needs node pressure)

The verifier only checks wiring. To *see* the behavior, make the node impossible to fit both tenants, then scale the critical one up:

```bash
# Give batch a giant memory request so it hogs schedulable capacity, then
# scale payments up: pending high-priority pods should preempt batch pods.
kubectl -n dojo-priority set resources deploy/batch --requests=memory=3Gi
kubectl -n dojo-priority scale deploy/batch --replicas=4
kubectl -n dojo-priority scale deploy/payments --replicas=4

kubectl -n dojo-priority get events --sort-by=.lastTimestamp | grep -i preempt
# -> "Preempted by ... pod ... on node ..."  — payments bumps batch off the node
kubectl -n dojo-priority get pods -o wide
```

Reset when done:

```bash
kubectl -n dojo-priority set resources deploy/batch --requests=memory=32Mi
kubectl -n dojo-priority scale deploy/batch --replicas=2
kubectl -n dojo-priority scale deploy/payments --replicas=2
```

## The failure mode to respect

The opposite of "no priorities" is "everything is critical." If three teams each declare their service `value: 2000000000`, you have re-created priority 0 with extra steps — and worse, you may now preempt genuine infrastructure. Keep a small, documented ladder (e.g. `critical=1000000`, `standard=1000`, `batch=100`), make `globalDefault` either unset or a low tier, and treat a request to add a new top-of-ladder class as a design review, not a config change.

## Hardening preview

In a shared cluster, pair priority with a **ResourceQuota scoped to a `PriorityClass`** so a team cannot mint unlimited high-priority pods and starve everyone else:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: critical-quota
  namespace: dojo-priority
spec:
  hard:
    pods: "10"
  scopeSelector:
    matchExpressions:
      - operator: In
        scopeName: PriorityClass
        values: ["dojo-critical"]
```

Now "critical" is both meaningful *and* bounded — the two properties a priority system needs to stay honest.
