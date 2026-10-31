# The Scheduler

> **Module 02 · Course 05** — In the last module you watched the scheduler PATCH `spec.nodeName` onto a `Pending` pod. This module is *how it decides which node*, and — the part that pays your salary at 2 a.m. — why it sometimes decides **nothing** and leaves your pod `Pending` forever. By the end you can read a scheduler's refusal straight out of `kubectl describe pod` Events and name the exact predicate that failed.

The scheduler is the purest reconcile loop in the system: it watches for pods with an empty `spec.nodeName`, and for each one it runs a two-phase pipeline and writes a binding. It does not run your containers — the kubelet does that once the pod is bound. The scheduler's entire job is choosing a name.

---

## The two-phase pipeline: filter, then score

For every pending pod the scheduler runs:

```
all nodes ──▶ [ FILTERING / predicates ] ──▶ feasible nodes ──▶ [ SCORING / priorities ] ──▶ pick highest ──▶ BIND
  (N)           "can this pod run here                (M ≤ N)       "how good is each            winner        PATCH
                 at all? yes/no"                                     feasible node? 0-100"                      nodeName
```

- **Filtering (predicates)** is a hard pass/fail. A node either *can* host the pod or it's eliminated. Checks include: does the node have enough allocatable CPU/memory for the pod's **requests**? Does it tolerate the node's taints? Do `nodeSelector`/`nodeAffinity` match its labels? Are the requested ports free? Can the required volumes attach here? **If filtering leaves zero nodes, the pod is `Unschedulable` — this is the #1 cause of stuck `Pending`.**
- **Scoring (priorities)** ranks the survivors 0–100 across plugins and sums weighted scores. It spreads pods across nodes (`NodeResourcesFit`, default `LeastAllocated`), honors `podAffinity`/`podAntiAffinity` and `topologySpreadConstraints`, prefers nodes that already have the image, and respects soft (`preferred…`) affinity. The highest total wins; ties break randomly.

The critical mental split: **filtering is correctness, scoring is optimization.** If your pod won't schedule, the problem is in filtering — scoring never even runs because there are no feasible nodes to rank.

```bash
# Watch the scheduler's own view of a pending pod (requires scheduler verbosity; on kind read Events instead)
kubectl describe pod <pod> | sed -n '/Events:/,$p'
# A FailedScheduling event literally lists how many nodes failed each predicate:
#   0/3 nodes are available: 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane}, 2 Insufficient cpu.
```

That one-line summary — `0/3 nodes are available: 2 Insufficient cpu, 1 untolerated taint` — is the scheduler telling you, predicate by predicate, why every node was eliminated. Learn to read it and you've learned 80% of scheduler debugging.

---

## Steering the scheduler: your toolbox

You influence placement with five mechanisms. Know which are hard (filtering) vs soft (scoring), because that determines whether a mismatch leaves you `Pending` or merely sub-optimal.

| Mechanism | Lives on | Hard or soft | Use it to |
|-----------|----------|--------------|-----------|
| `nodeSelector` | Pod | **Hard** (filter) | Pin to nodes with a label, e.g. `disktype: ssd`. Simplest, exact-match only. |
| `nodeAffinity` | Pod | Hard *or* soft | `requiredDuringScheduling…` = filter; `preferredDuringScheduling…` = score. Supports `In/NotIn/Exists` operators. |
| `podAffinity` / `podAntiAffinity` | Pod | Hard *or* soft | Co-locate with / spread away from *other pods* ("keep cache near its app", "never two replicas on one node"). |
| Taints & Tolerations | Taint on **Node**, toleration on **Pod** | **Hard** (filter) | *Repel* pods from a node unless they explicitly tolerate it. The inverse of affinity: nodes reject pods, not pods choosing nodes. |
| `topologySpreadConstraints` | Pod | Hard *or* soft (`whenUnsatisfiable`) | Even distribution across a topology key (zone, hostname). The modern replacement for anti-affinity-for-spreading. |

### Taints & tolerations — the one people get backwards

Affinity is the pod being picky. **Taints are the node being picky.** A taint says "keep pods off me unless they prove they belong." The control-plane node is tainted exactly this way, which is why your workloads land on workers:

```bash
# The control-plane node carries a NoSchedule taint by default
kubectl describe node dojo-control-plane | grep -i taints
# -> Taints: node-role.kubernetes.io/control-plane:NoSchedule

# Taint a worker so only tolerating pods land there
kubectl taint nodes dojo-worker dedicated=gpu:NoSchedule
```

Taint **effects**:

| Effect | Meaning |
|--------|---------|
| `NoSchedule` | New pods without a matching toleration won't be scheduled here. Already-running pods stay. |
| `PreferNoSchedule` | Soft version — scheduler *tries* to avoid, but will place here if nothing else fits. |
| `NoExecute` | New pods need a toleration **and** already-running pods without one are **evicted**. This is how the node controller evicts pods from a `NotReady` node (via the `node.kubernetes.io/not-ready` taint). |

A pod tolerates with:

```yaml
tolerations:
  - key: dedicated
    operator: Equal
    value: gpu
    effect: NoSchedule
```

> **Toleration ≠ attraction.** A toleration only grants *permission* to land on a tainted node; it does not *pull* the pod there. If you want "GPU pods go to GPU nodes **and** nothing else goes there," you need the taint (repel everything else) **plus** a `nodeSelector`/affinity (attract the GPU pods). People forget the second half and wonder why their GPU node sits empty while GPU pods spread everywhere.

### topologySpreadConstraints — spreading done right

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule   # hard: Pending if it can't stay within skew
    labelSelector:
      matchLabels:
        app: web
```

`maxSkew: 1` across `hostname` means "no node may have more than 1 extra replica over the least-loaded node." `whenUnsatisfiable: DoNotSchedule` makes it a **filter** (hard) — so on a 3-node cluster, a 4th replica of a 3-way-spread app can go `Pending` if a node is cordoned. Switch to `ScheduleAnyway` to make it a scoring preference instead. This is a classic self-inflicted `Pending`: a hard spread constraint plus a drained node.

---

## Why your pod is Pending: the decision tree

`Pending` means **not yet bound to a node**. There are only a few reasons, and they're all readable from Events + node state:

```
Pod Pending
   │
   ├─ Events show "FailedScheduling"?  ──► the SCHEDULER can't place it. Read the reason:
   │      ├─ "Insufficient cpu/memory"      → sum of requests > allocatable on every node
   │      ├─ "untolerated taint"            → needs a toleration (or you tainted all nodes)
   │      ├─ "didn't match node selector/affinity" → labels don't match any node
   │      ├─ "didn't match pod affinity/anti-affinity rules" → contradictory co-location rules
   │      ├─ "didn't find available persistent volumes" / "node had volume node affinity conflict" → PV zone mismatch
   │      └─ "node(s) didn't satisfy topology spread constraints" → maxSkew can't be honored
   │
   ├─ No scheduling events at all, ever?  ──► the SCHEDULER isn't running (see Module 01)
   │
   └─ Bound (has nodeName) but still Pending/ContainerCreating? ──► NOT a scheduler problem — it's the
          kubelet/CNI/image pull. That's Module 03 territory, not this one.
```

That last branch is the one that wastes hours: once `spec.nodeName` is set, the scheduler is *done* and the pod is the kubelet's problem. `Pending` with a node assigned is never a scheduling bug.

---

## Capacity math: requests, not limits, not usage

The single most common `Insufficient cpu` surprise comes from confusing three numbers:

- **Requests** — what the scheduler reserves. **This is the only number scheduling cares about.**
- **Limits** — the ceiling the kubelet/cgroups enforce at runtime. Irrelevant to scheduling.
- **Actual usage** — what `kubectl top` shows. Also irrelevant to scheduling.

A node with 4 cores can be at 5% *actual* CPU and still refuse a pod requesting `2` cores if existing pods have already **requested** 3 cores — the scheduler reserves against requests, not against live usage. Over-generous requests silently strand capacity.

```bash
# What's actually reserved vs allocatable on each node — the numbers the scheduler uses
kubectl describe node dojo-worker | sed -n '/Allocated resources/,/Events/p'
# Allocatable (total schedulable) vs your pod's requests
kubectl get node dojo-worker -o jsonpath='{.status.allocatable.cpu}{"  "}{.status.allocatable.memory}{"\n"}'
# Requires metrics-server (labs/bootstrap/install-metrics-server.sh) — this is USAGE, not requests:
kubectl top nodes
```

---

## Debugging unschedulable pods

The workflow is always the same: `describe` the pod, read the `FailedScheduling` reason, then check node state to confirm which predicate it means.

| Symptom (`FailedScheduling` reason) | Likely cause | Diagnose with | Fix |
|-------------------------------------|--------------|---------------|-----|
| `Insufficient cpu` / `Insufficient memory` | Sum of pod **requests** exceeds every node's allocatable | `kubectl describe node <n>` → *Allocated resources* | Lower requests, add a node, or scale down neighbors |
| `had untolerated taint {…}` | Node tainted (control-plane, dedicated pool, or `NotReady`) | `kubectl describe node <n> \| grep -i taints` | Add a matching `toleration`, or target a different node |
| `didn't match Pod's node affinity/selector` | `nodeSelector`/`requiredDuringScheduling` affinity matches no node's labels | `kubectl get nodes --show-labels` | Fix the label value, or label a node |
| `didn't match pod anti-affinity rules` | Hard anti-affinity wants N replicas on N distinct nodes but fewer exist | `kubectl get pods -o wide` (see where siblings are) | Loosen to `preferred…`, or add nodes |
| `node(s) didn't satisfy topology spread` | `maxSkew` + `DoNotSchedule` can't be honored (e.g. a node cordoned) | `kubectl get nodes` (any `SchedulingDisabled`?) | `uncordon` the node, raise `maxSkew`, or use `ScheduleAnyway` |
| `node(s) had volume node affinity conflict` | Pod's PV is zonal; no feasible node in that zone | `kubectl get pv <pv> -o jsonpath='{.spec.nodeAffinity}'` | Schedule where the volume lives, or use a non-zonal StorageClass |
| `0/N nodes are available` but no reason, no events | Scheduler not running | `crictl ps --name kube-scheduler` (Module 01) | Restart the scheduler static pod |

The commands you'll actually run, in order:

```bash
# 1. The verdict — Events at the bottom name the failing predicate(s) and the node count
kubectl describe pod <pod> | sed -n '/Events:/,$p'

# 2. Same info as structured output (scriptable; survives event expiry better)
kubectl get event --field-selector involvedObject.name=<pod>,reason=FailedScheduling \
  -o custom-columns=TIME:.lastTimestamp,MSG:.message

# 3. Confirm the predicate against node reality
kubectl get nodes -o wide
kubectl get nodes --show-labels
kubectl describe node <node> | grep -i taints
kubectl describe node <node> | sed -n '/Allocated resources/,/Events/p'

# 4. What does the pod actually ask for? (requests + affinity + tolerations in one shot)
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].resources.requests}{"\n"}{.spec.tolerations}{"\n"}{.spec.affinity}{"\n"}'

# 5. Force a reproduction in the lab: taint every node, apply a pod, watch it stick
kubectl taint nodes --all demo=yes:NoSchedule
kubectl -n dojo-sched run box --image=nginx:1.27-alpine
kubectl -n dojo-sched describe pod box | sed -n '/Events:/,$p'   # -> all nodes untolerated taint
kubectl taint nodes --all demo=yes:NoSchedule-                    # cleanup (trailing - removes)
```

> **War story.** A payments service was pinned to its own node pool with `nodeSelector: pool=payments` plus a hard `podAntiAffinity` so no two replicas shared a node — textbook isolation. It ran 3 replicas on a 3-node pool for a year. Then capacity planning bumped it to `replicas: 4` in a routine PR. The 4th pod went `Pending` and stayed there; the on-call engineer saw a healthy-looking Deployment (`3/4 ready`) and assumed a slow rollout. Twenty minutes later `kubectl describe pod` finally got read: `didn't match pod anti-affinity rules`. The hard anti-affinity needed a 4th node that didn't exist, so the scheduler *correctly* refused — there was no bug, the constraint was doing exactly what it said. The fix was a one-line change: `requiredDuringSchedulingIgnoredDuringExecution` → the equivalent `topologySpreadConstraints` with `whenUnsatisfiable: ScheduleAnyway`, which prefers spreading but won't wedge at `Pending` when the pool is full. The lesson: **a hard scheduling constraint is a promise you'll have the capacity to keep.** Scale past it and the scheduler keeps the promise by leaving pods `Pending`.

> **War story, the quiet one.** Half a cluster's pods slowly drifted onto two nodes while six sat nearly empty. No alerts — everything was `Running`. The cause was requests, not placement rules: a base image's Helm chart defaulted `resources.requests.cpu: 1000m` for a workload that actually used `20m`. The scheduler dutifully reserved a full core per replica, so nodes "filled up" at 4 pods each against real usage of 8%. `kubectl top nodes` showed 10% CPU while `kubectl describe node` showed 100% CPU *requested*. The fix was right-sizing requests to observed usage; the lesson is that **the scheduler packs against requests you declared, not the load you actually impose** — and lazy requests waste money by stranding real capacity.

---

## Checkpoint

You've got this module when you can, without looking it up:

1. Describe the two-phase pipeline (filter → score) and explain why a stuck `Pending` pod is almost always a *filtering* failure, not scoring.
2. State which of `nodeSelector` / affinity / taints / topology spread are hard (filter) vs soft (score), and explain why a toleration grants permission but not attraction.
3. Read a `FailedScheduling` event like `0/3 nodes are available: 2 Insufficient cpu, 1 untolerated taint` and say exactly what to check next.
4. Explain why the scheduler reserves against **requests**, not limits or live usage, and find a node's allocated-vs-allocatable with `kubectl describe node`.
5. Distinguish "Pending because unschedulable" (scheduler's problem) from "Pending with a nodeName" (kubelet/CNI's problem — Module 03).
6. Reproduce an unschedulable pod in the lab by tainting all nodes, read the Event, and clean the taint off.

➡ Next up: **CNI & CRI** — the pod got bound to a node; now the kubelet has to actually pull the image, create the sandbox, and wire it onto the pod network. We go down to `crictl` and the pod's network namespace.
