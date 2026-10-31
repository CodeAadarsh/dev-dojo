# PodDisruptionBudgets & Safe Draining

> **Module 04 · Course 02** — Every node in your fleet will go away. The only question is whether it leaves on *your* terms or the universe's. Node upgrades, cluster-autoscaler scale-downs, kernel patches, and spot reclaims are all **voluntary** disruptions — planned, throttleable, survivable. A kernel panic at 3am is **involuntary** — you don't get a vote. This module is about the machinery that separates the two: `PodDisruptionBudget`, `cordon`/`drain`, and the pod termination lifecycle that decides whether an in-flight request gets finished or dropped on the floor.

You already run rolling node upgrades at work. This module is slow on the exact mechanics that make the difference between a drain that quietly rolls your whole fleet and a drain that pages you because it evicted every replica of a service at once — or worse, one that *looks* graceful but severs live connections because your pods never learned to die politely.

---

## Two kinds of death: voluntary vs involuntary

The single most important distinction in this module, because **a PDB only governs one of them.**

```
         DISRUPTIONS
        /            \
 INVOLUNTARY         VOLUNTARY
 (no PDB help)       (PDB-governed via the Eviction API)
 ───────────         ──────────────────────────────────
 • kernel panic      • kubectl drain (node upgrade)
 • node OOM / hw die  • cluster-autoscaler scale-down
 • VM/spot reclaim*   • kubectl delete pod (by an admin)
 • network partition  • rolling node-pool upgrade
 • accidental node    • kubectl evict (/eviction subresource)
   termination
```

A `PodDisruptionBudget` is a *promise the cluster keeps to you during voluntary disruptions*: "no voluntary action may take me below N healthy pods." It is **not** a replica guarantee. If a node hosting two of your three replicas catches fire, the PDB does nothing — those pods are gone, involuntarily, and your only recovery is the ReplicaSet rescheduling them onto surviving nodes.

> **\*The spot-instance asterisk.** Cloud spot/preemptible reclaim is *technically* involuntary from Kubernetes' point of view (the node vanishes), but mature setups install a node-termination handler (AWS NTH, GKE graceful shutdown) that catches the cloud's ~30–120s warning and converts it into a **voluntary drain** so your PDB and grace periods actually apply. The lesson: the voluntary/involuntary line is partly something you *engineer*, not a fixed law. The more disruptions you can pull across into the "voluntary" column, the more of them your PDB can throttle.

The practical consequence: **a PDB is worthless without enough replicas and anti-affinity to survive the involuntary case too.** PDBs throttle planned churn; replicas + spread survive unplanned loss. You need both.

---

## PodDisruptionBudget: the two knobs

A PDB has exactly one of two mutually-exclusive fields. Setting both is a validation error.

| Field | Meaning | Good for |
|-------|---------|----------|
| `minAvailable` | Keep *at least* this many healthy pods at all times | Stateless services where you think in "floor" |
| `maxUnavailable` | Allow *at most* this many pods down at once | Fleets where you think in "how much churn can I take" |

Both accept an **absolute integer** (`2`) or a **percentage** (`50%`). The selector picks which pods the budget covers.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
  namespace: dojo-drain
spec:
  minAvailable: 2          # or: maxUnavailable: 1  (never both)
  selector:
    matchLabels:
      app: web
```

### Percentage rounding — the detail that bites

Percentages are resolved against the number of pods the controller *expects* (from the owning ReplicaSet/StatefulSet scale), and the rounding direction is not symmetric:

- `minAvailable: 50%` **rounds up**. With 5 pods that's `ceil(2.5) = 3` must stay healthy.
- `maxUnavailable: 50%` **rounds down** to the number allowed down, i.e. it also keeps *more* pods up. With 5 pods, `maxUnavailable: 50%` → at most `floor(2.5) = 2` down → 3 stay up.

Both directions round *in favor of availability*. When in doubt, use integers — they're unambiguous and they're what you want for small replica counts anyway.

### How the budget is actually enforced: the Eviction API

This is the part most people never look at, and it explains every "why is my drain stuck" question you'll ever field.

```
  kubectl drain node-7
        │
        ▼
  POST .../pods/<pod>/eviction        ← NOT a DELETE. The Eviction subresource.
        │
        ▼
  API server asks: does evicting this pod leave
  the PDB with >= desiredHealthy pods?
        │
   ┌────┴─────┐
   │          │
  YES        NO
   │          │
   ▼          ▼
 pod deleted  429 Too Many Requests
 gracefully   "Cannot evict pod as it would violate
              the pod's disruption budget."
                   │
                   ▼
            drain BACKS OFF and RETRIES
            (loops until a replacement pod
             goes Ready elsewhere, freeing budget)
```

The magic number is `.status.disruptionsAllowed` on the PDB. The eviction endpoint grants an eviction only while that counter is `> 0`, decrements it, and the PDB controller refills it as replacement pods become **Ready** (not just Running — readiness is what counts toward `currentHealthy`). This is why a drain of a healthy, well-budgeted service proceeds pod-by-pod at exactly the pace replacements come up. It's cooperative back-pressure, not a lock.

```bash
kubectl -n dojo-drain get pdb web-pdb
# NAME      MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
# web-pdb   2               N/A               1                     3m

# the full status is where the truth lives:
kubectl -n dojo-drain get pdb web-pdb -o jsonpath='{.status}' | tr ',' '\n'
# currentHealthy, desiredHealthy, expectedPods, disruptionsAllowed
```

> **One pod, one PDB.** A pod matched by *two* PDBs cannot be evicted at all — the eviction API refuses because it can't reason about overlapping budgets. Keep selectors disjoint. `kubectl get pdb -A -o wide` and eyeball the selectors if you suspect overlap.

---

## cordon vs drain vs uncordon

These three are often blurred together. They are distinct operations and knowing exactly what each one does is the difference between a clean node rotation and an outage.

| Command | What it changes | Evicts pods? | Blocks new pods? |
|---------|-----------------|--------------|------------------|
| `kubectl cordon <node>` | Sets `.spec.unschedulable: true` (+ `node.kubernetes.io/unschedulable:NoSchedule` taint) | No | Yes |
| `kubectl drain <node>` | cordon **+** evict every eligible pod via the Eviction API | Yes | Yes |
| `kubectl uncordon <node>` | Clears unschedulable | No | No (re-enables scheduling) |

`cordon` is the "stop the bleeding" move: it freezes new placement onto a suspect node without touching what's already there, giving you time to investigate. `drain` is cordon plus the eviction loop. Always `uncordon` when you're done, or that node silently sits idle forever — a classic way to lose a third of your capacity without noticing.

### The drain flags you must know

A bare `kubectl drain node-7` almost always errors on a real cluster, because drain is deliberately conservative and refuses to destroy anything it can't safely recreate:

```bash
kubectl drain dojo-worker \
  --ignore-daemonsets \          # DaemonSet pods are recreated per-node; skip them (REQUIRED on nearly every node)
  --delete-emptydir-data \       # acknowledge: emptyDir volumes on these pods WILL be lost
  --grace-period=30 \            # override the pod's terminationGracePeriodSeconds (-1 = use the pod's own)
  --timeout=120s \               # give up (don't hang forever) if eviction can't complete
  --pod-selector app=web         # optional: only drain pods matching a selector
```

Three flags correspond to three deliberate safety refusals:

- **`--ignore-daemonsets`** — drain won't evict DaemonSet-managed pods (a DaemonSet would just recreate them on the same, now-cordoned node, so eviction is pointless). Without this flag, drain *errors* rather than silently skipping. You will pass this on essentially every drain, because every node runs kube-proxy, CNI, and log/metric agents as DaemonSets.
- **`--delete-emptydir-data`** — drain refuses to evict a pod with an `emptyDir` volume unless you explicitly accept the data loss. This is a guard against nuking a pod's scratch/cache data you forgot was ephemeral.
- **`--force`** — drain refuses to evict **bare pods** (pods with no controller — no ReplicaSet, Job, StatefulSet, etc.) because nothing will recreate them. `--force` says "delete them anyway, I accept they won't come back." A bare pod is almost always a mistake in production; drain surfacing it is a feature.

### The dangerous flag: `--disable-eviction`

```bash
kubectl drain dojo-worker --disable-eviction   # ☠ uses DELETE, not the Eviction API
```

`--disable-eviction` makes drain issue raw `DELETE` calls instead of going through the eviction subresource — which means it **completely bypasses every PodDisruptionBudget**. It exists for breaking a stuck drain in an emergency. Treat it like `rm -rf`: it is the thing that turns "the drain is slow" into "the service is down." Never put it in automation.

---

## The pod termination lifecycle — where connections get dropped

A PDB decides *whether* a pod may be evicted. The termination lifecycle decides *whether that eviction loses traffic*. Most "graceful shutdown" bugs live entirely here, and the root cause is almost always the same: two things happen **in parallel** and people assume they're sequential.

```
 eviction/delete accepted, deletionTimestamp set
        │
        ├──────────────────────────┬───────────────────────────────┐
        ▼                          ▼                                 │
 (A) pod removed from          (B) preStop hook runs                 │
     Endpoints/EndpointSlice       (if defined), THEN                │
     → kube-proxy, ingress,        SIGTERM sent to PID 1             │  these two
       and service mesh                │                             │  run CONCURRENTLY
       stop routing to it             ▼                              │
     (ASYNC — propagates          app should stop accepting new,     │
      across the fleet over       finish in-flight, then exit        │
      a few hundred ms)                │                             │
        │                             ▼                              │
        └────────────── terminationGracePeriodSeconds clock ─────────┘
                                      │
                       grace period (default 30s) elapses
                                      │
                                      ▼
                            SIGKILL — pod dies hard,
                            any remaining connections severed
```

The race that drops connections: **endpoint removal (A) is eventually-consistent and asynchronous.** For a few hundred milliseconds after SIGTERM, some proxy somewhere may still send a brand-new request to a pod that has already started shutting down. If your app saw SIGTERM and immediately closed its listener, that request gets a connection refused / reset.

The fix is a `preStop` hook that simply **waits**, buying time for endpoint removal to propagate *before* SIGTERM reaches the app:

```yaml
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 45       # must exceed preStop sleep + real drain time
      containers:
        - name: web
          image: nginx:1.27-alpine
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 10"]   # let endpoint removal propagate
```

The sequence that actually gives you zero-downtime shutdown:

1. Eviction accepted → pod enters `Terminating`, endpoint removal **starts** (async).
2. `preStop` runs `sleep 10` — the pod is still fully serving existing and in-flight requests during this window, but the fleet is learning not to send *new* ones.
3. `preStop` finishes → `SIGTERM` to PID 1. By now, routing has stopped, so the app can drain in-flight work and exit cleanly.
4. App exits (or grace period expires → `SIGKILL`).

### The grace-period budget — add it up

`terminationGracePeriodSeconds` is a **total budget** that covers `preStop` **plus** the app's own SIGTERM handling. It is not time *in addition to* preStop. If preStop sleeps 10s and your app needs 25s to finish long requests, you need a grace period of at least 35s — set it to 30 (the default) and the app gets SIGKILLed mid-request at the 30s mark, 5s short.

| Value | Effect |
|-------|--------|
| `terminationGracePeriodSeconds: 30` | Default. Fine for fast, stateless HTTP. |
| `terminationGracePeriodSeconds: 0` | **Immediate SIGKILL, no SIGTERM, no preStop.** Data/connection loss. Only for truly disposable pods. |
| Grace period < (preStop + app shutdown) | App is SIGKILLed mid-shutdown — the exact bug you were trying to prevent. |
| Very large (e.g. 600) | Slow, "stuck"-looking drains; a wedged pod holds the node for 10 minutes. |

> **PID 1 and signal forwarding.** If your container's entrypoint is a shell (`sh -c "myapp"`), the shell is PID 1 and **does not forward SIGTERM** to `myapp` by default — so your carefully-written SIGTERM handler never runs, and the pod just waits out the whole grace period and gets SIGKILLed every single time. Fix: `exec` your app so it becomes PID 1 (`sh -c "exec myapp"`), or run with an init shim (`tini`, or the pod's `shareProcessNamespace`/`initContainers` patterns). This is the number-one reason "graceful shutdown doesn't work" in otherwise-correct setups.

---

## Debugging drains, PDBs & termination

Diagnose in order of cheapest signal. For draining, the first question is always *"is the drain blocked, or is it working slowly on purpose?"* — those look identical from the terminal.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Drain hangs; `error ... Cannot evict pod ... would violate the pod's disruption budget` | PDB `disruptionsAllowed` is 0 — replacements aren't going Ready fast enough, or the PDB is too strict | Check `kubectl get pdb`; ensure replicas can reschedule (free capacity on other nodes); wait — this is often correct back-pressure |
| Drain blocked *forever*, `ALLOWED DISRUPTIONS` stuck at `0` with all pods healthy | **PDB deadlock**: `minAvailable == replicas` (or `maxUnavailable: 0`) — no eviction can ever be allowed | Loosen the PDB (`minAvailable` < replicas) or scale up first; never ship `minAvailable == spec.replicas` |
| Drain errors: `cannot delete DaemonSet-managed Pods` | Missing `--ignore-daemonsets` | Re-run with `--ignore-daemonsets` |
| Drain errors: `cannot delete Pods with local storage` | A pod has an `emptyDir`; drain won't destroy its data silently | `--delete-emptydir-data` (after confirming the data is truly ephemeral) |
| Drain errors: `cannot delete Pods not managed by ...` | **Bare pods** with no controller — nothing will recreate them | `--force` (accept they're gone), or adopt them under a controller |
| Connections dropped / 502s during a rollout or drain, even with a PDB | Endpoint-removal race: no `preStop` wait, so new traffic hit a pod already shutting down | Add `preStop: sleep 5–15` and ensure grace period covers it |
| Pods SIGKILLed every time; app's SIGTERM handler never fires | PID 1 is a shell not forwarding signals, **or** grace period < shutdown time | `exec` the app as PID 1 (or add `tini`); raise `terminationGracePeriodSeconds` |
| `ALLOWED DISRUPTIONS 0` but pods look "up" | PDB counts **Ready** pods; a failing readiness probe drops `currentHealthy` below `desiredHealthy` | Fix the readiness probe; `kubectl get pod` and check the READY column, not just STATUS |
| Pod matched by two PDBs, eviction always refused | Overlapping PDB selectors — eviction can't reason about both | Make selectors disjoint; `kubectl get pdb -A` and compare `.spec.selector` |

### Diagnose each — the exact commands

**Is the drain blocked by a PDB, and by how much?** Watch the budget's live counters while the drain runs:

```bash
kubectl -n dojo-drain get pdb -o custom-columns=\
NAME:.metadata.name,MIN:.spec.minAvailable,ALLOWED:.status.disruptionsAllowed,\
HEALTHY:.status.currentHealthy,DESIRED:.status.desiredHealthy,EXPECTED:.status.expectedPods
# ALLOWED=0 while HEALTHY==DESIRED  → correct back-pressure; drain is pacing itself.
# ALLOWED=0 while HEALTHY<DESIRED   → pods aren't Ready; the readiness probe or scheduling is the problem.
```

The 429s from the eviction API show up as warning events — proof the throttle is doing its job, not a failure:

```bash
kubectl -n dojo-drain get events --sort-by=.lastTimestamp | grep -i evict
```

**Detect a PDB deadlock before it bites.** If `minAvailable` equals the controller's replica count, no voluntary eviction can ever succeed:

```bash
# compare PDB minAvailable against the deployment's replicas
kubectl -n dojo-drain get pdb web-pdb -o jsonpath='{.spec.minAvailable}{"\n"}'
kubectl -n dojo-drain get deploy web -o jsonpath='{.spec.replicas}{"\n"}'
# if they're equal (e.g. 3 and 3), the PDB will wedge every drain forever.
```

**Verify what a node actually holds before draining it** (so you know what you're about to move, and spot bare pods early):

```bash
kubectl get pods -A --field-selector spec.nodeName=dojo-worker -o wide
# look for pods whose OWNER isn't a controller — those will block drain without --force
kubectl get pods -A --field-selector spec.nodeName=dojo-worker \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.metadata.ownerReferences[0].kind}{"\n"}{end}'
# an empty ownerReferences kind == a bare pod.
```

**Inspect the real cordon state on the node** (kind nodes are containers, so you can drop a level when kubectl is ambiguous):

```bash
kubectl get node dojo-worker -o jsonpath='{.spec.unschedulable}{"\n"}'   # true == cordoned
kubectl describe node dojo-worker | grep -i taint
docker exec dojo-control-plane crictl pods | head    # what the node runtime still has running
```

**Prove a pod actually honors SIGTERM.** Send it and watch — if the pod sits for the full grace period then dies with no clean-exit log line, PID 1 isn't forwarding the signal:

```bash
kubectl -n dojo-drain delete pod <pod> --grace-period=45 &
kubectl -n dojo-drain get pod <pod> -w     # should go Terminating → gone well before 45s if shutdown is clean
# exit reason after the fact:
kubectl -n dojo-drain get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
```

> **War story.** During a routine Kubernetes minor-version upgrade on the LGTM pipeline at SAP, the node-pool roll stalled on a single ingestion Deployment and the upgrade window blew past its SLO. The drain log just said *"evicting pod ... Cannot evict pod as it would violate the pod's disruption budget"* on a loop — which I first read as "the PDB is doing its job, be patient." It wasn't. Someone had shipped `minAvailable: 6` on a Deployment whose `replicas` was *also* 6, to "be safe." `disruptionsAllowed` was mathematically pinned at 0: the cluster could never evict even one pod without violating the budget, so the drain would have looped until the heat death of the universe. The fix was one character — `minAvailable: 5` — and the roll completed in minutes. The lesson I tattooed on my brain: **a PDB whose floor equals the replica count isn't strict, it's a deadlock.** Now every PDB review I do checks exactly one inequality: `minAvailable < replicas`. If they're equal, it's not a budget, it's a brick wall.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. State the difference between a voluntary and an involuntary disruption, and which one a PDB governs — plus one trick (node-termination handlers) that moves a disruption from the involuntary column to the voluntary one.
2. Explain why a PDB is not a replacement for replicas + anti-affinity, using the "node catches fire" case.
3. Choose between `minAvailable` and `maxUnavailable`, and say which way each rounds when given a percentage.
4. Describe, end to end, how a `kubectl drain` interacts with the Eviction API and `.status.disruptionsAllowed`, including what the 429 does.
5. Spot a PDB deadlock from `minAvailable` vs `replicas` alone, and name the one inequality that must always hold.
6. List the three drain refusals (`--ignore-daemonsets`, `--delete-emptydir-data`, `--force`) and why each exists, and explain why `--disable-eviction` is dangerous.
7. Walk through the pod termination lifecycle and explain the endpoint-removal race that a `preStop` sleep fixes.
8. Add up a grace-period budget (preStop + app shutdown) and explain the PID-1 signal-forwarding trap that makes SIGTERM handlers silently never run.
9. Tell apart a drain that's blocked-forever from one that's correctly pacing itself, using only the PDB's live `disruptionsAllowed` / `currentHealthy` / `desiredHealthy` counters.

➡ Next up: **Autoscaling: HPA, VPA & Cluster Autoscaler** — now that you can move pods off a node safely, you'll make the cluster add and remove pods *and nodes* on demand, and learn why the autoscaler and the drain you just mastered are the same control loop viewed from two ends.
