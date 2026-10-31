# Resource Management & QoS

> **Module 02 · Course 02** — You already set `requests` and `limits` at work because a linter or an admission webhook makes you. This module is about what those two numbers *actually do* once the pod is scheduled: how they pick the node, which pod the kernel kills first under memory pressure, why a pod pinned at 40% CPU can still be desperately slow, and how to size them from real metrics instead of superstition. Get this wrong and you either waste half your cluster on padding or you get paged at 3am for an `OOMKilled` that was mathematically inevitable the day you wrote the manifest.

Resource management is where reliability and cost collide. Every millicore and megabyte you *request* is capacity the scheduler fences off for you whether you use it or not; every `limit` you set is a ceiling the kernel will enforce with a `SIGKILL` or a throttle. The gap between the two is the single most misunderstood thing in production Kubernetes, and it's where most of the "it's slow but nothing is wrong" tickets come from.

---

## requests vs limits — two different jobs, two different enforcers

The mistake almost everyone makes early is treating `requests` and `limits` as "min and max of the same thing." They are not. They are consumed by **different components at different times** and they govern **different resources differently**.

| | `requests` | `limits` |
|---|-----------|----------|
| **Who reads it** | The **scheduler** (`kube-scheduler`), at placement time | The **kubelet / container runtime / kernel**, at runtime |
| **When it matters** | Once, when the pod is being placed on a node | Continuously, every scheduling quantum the container runs |
| **What it guarantees** | A reservation — the node *promises* you at least this much | A ceiling — you will never get *more* than this |
| **If you exceed it** | Nothing (you can burst above requests freely) | CPU: **throttled**. Memory: **OOM-killed** |
| **Drives** | Scheduling, QoS class, HPA utilization denominator | Throttling, OOM, cgroup limits |

The two load-bearing facts:

```
 ┌──────────────────────────────────────────────────────────────┐
 │  requests  →  SCHEDULING + GUARANTEE   (how much is reserved)  │
 │  limits    →  RUNTIME ENFORCEMENT      (how much is the cap)   │
 └──────────────────────────────────────────────────────────────┘

   node allocatable = capacity - (kube-reserved + system-reserved + eviction-threshold)
   the scheduler fits the SUM OF REQUESTS into allocatable. limits are ignored for fit.
```

Internalize these consequences:

- **The scheduler only ever looks at `requests`.** A node with 4 CPUs of allocatable will accept pods whose *requests* sum to 4 CPUs, even if their *limits* sum to 40. This is deliberate oversubscription — it's how clusters stay affordable — and it's also why a node can be "only 60% requested" yet fall over when everyone bursts to their limits at once.
- **`limits` never affect whether a pod fits.** You can set a 64Gi memory limit on a 2Gi node; the scheduler won't stop you, because it schedules on requests. The pod lands and then gets OOM-killed the instant it actually tries to use that memory. This surprises people constantly.
- **CPU and memory are enforced completely differently.** CPU is a *compressible* resource — exceed the limit and you're throttled (slowed), never killed. Memory is *incompressible* — exceed the limit and there is no "slow down," only death by OOM. This asymmetry is the root of half this module.

> **Units, precisely.** CPU `1` = 1 vCPU/core; `500m` = 0.5 core = 500 "millicores"; `100m` = a tenth of a core. Memory `Mi`/`Gi` are **power-of-two** (1 Mi = 1,048,576 bytes), `M`/`G` are **power-of-ten** (1 M = 1,000,000 bytes). People write `memory: 512M` meaning 512 mebibytes and are quietly short by ~5% — always use `Mi`/`Gi`. The kernel measures memory in bytes and does not care about your intent.

---

## The three QoS classes — and why they're derived, not declared

You do **not** set a pod's QoS class. Kubernetes *computes* it from how your requests and limits relate, and then the kubelet uses that class to decide eviction and OOM order. This is one of the most leverage-per-byte concepts in the whole platform, because the class you get for free changes who dies first under pressure.

```
          ┌─ every container has requests == limits (for BOTH cpu AND memory) ─┐
          │                                                                    │
  Guaranteed ◀── highest protection ── last to be killed ── OOM score ~ -997   │
          │                                                                    │
  Burstable  ◀── at least one request set, but not Guaranteed ── OOM score varies
          │                                                                    │
  BestEffort ◀── NO requests and NO limits anywhere ── first to die ── OOM ~ 1000
          └────────────────────────────────────────────────────────────────────┘
```

The exact derivation rules:

| QoS class | Condition | Eviction / OOM priority |
|-----------|-----------|-------------------------|
| **Guaranteed** | For **every** container: `requests == limits` for **both** CPU and memory (and both are set) | Protected — evicted/killed **last** |
| **Burstable** | Not Guaranteed, but **at least one** container has a CPU or memory request or limit | Middle — killed by how far it exceeds its *request* |
| **BestEffort** | **No** requests and **no** limits on **any** container | First to die under node pressure |

Check it directly:

```bash
kubectl get pod <name> -o jsonpath='{.status.qosClass}{"\n"}'
# -> Guaranteed | Burstable | BestEffort
```

### OOM-kill ordering — the kernel's math, made concrete

When a **node** runs out of memory, two different mechanisms can fire, and you must know which:

1. **kubelet eviction (node-pressure eviction)** — the kubelet watches node memory against its eviction threshold and *proactively* evicts whole pods *before* the kernel panics. It ranks victims by QoS first (BestEffort → Burstable → Guaranteed) and then, within Burstable, by how far each pod's usage exceeds its memory **request**. Evicted pods show `Status: Evicted` and get rescheduled elsewhere.
2. **Kernel OOM killer** — if memory is exhausted faster than the kubelet can react, the Linux OOM killer fires inside the cgroup and kills a single *process* (usually your container's PID 1). This shows as `OOMKilled` with exit code **137**.

The kubelet biases the kernel's choice by writing each container's `oom_score_adj` based on QoS:

```
 oom_score_adj (lower = more protected):
   Guaranteed  :  -997
   BestEffort  :  1000     ← kernel kills these first
   Burstable   :  computed between 2 and 999, scaled by:
                  1000 - (1000 * memory_request / node_allocatable_memory)
                  → the SMALLER your request relative to the node, the HIGHER
                    your score, the SOONER you die.
```

The practical takeaway: a Burstable pod with a tiny memory request and a huge actual footprint is the kernel's favourite meal. **Setting a realistic memory request is not just about scheduling — it's your pod's life insurance under pressure.**

> **When a container exceeds its OWN memory limit**, it doesn't matter what else is happening on the node — the kernel OOM-kills it inside its own cgroup immediately. This is "single-container OOM" and it's the common case in dev: your Java/Node heap grew past `limits.memory`, exit 137, `CrashLoopBackOff`. The node had plenty of free RAM; *you* just hit *your* ceiling.

---

## CPU throttling — the slowness with no error

This is the single most under-diagnosed performance problem in Kubernetes, because **nothing fails**. No restart, no event, no log line. Your p99 latency just quietly triples and you spend a day blaming the database.

CPU limits are enforced by the Linux kernel's **CFS bandwidth control** (Completely Fair Scheduler). The limit is not "a number of cores" — it's a **quota of CPU-time per period**:

```
 CFS bandwidth: in every PERIOD (default 100ms), your cgroup gets QUOTA microseconds of CPU.

   limits.cpu: 500m   →  quota = 50ms  per 100ms period
   limits.cpu: 1       →  quota = 100ms per 100ms period
   limits.cpu: 2       →  quota = 200ms per 100ms period (can use 2 cores for the full period)

 Burn your quota before the period ends → you are THROTTLED (parked) until the next period.
```

Here's the trap that bites real services: a **bursty, multi-threaded** app with a modest average CPU can be throttled hard even though `kubectl top` shows it at 30% utilization. Say you have `limits.cpu: 1` (100ms quota per 100ms). A request comes in, your thread pool wakes 4 threads, they each want 40ms of CPU *right now* — that's 160ms of demand in a 100ms window. You get 100ms, then the kernel parks every thread for the rest of the period. Averaged over a minute you look idle; per-100ms-slice you're stalling on every single request.

```
  period: |----100ms----|----100ms----|----100ms----|
  demand:  ████████▓▓▓▓    (wants 160ms)
  granted: ████████░░░░    throttled here → latency spike
                   ▲ parked until next period boundary
```

Diagnose it from the container's own cgroup counters — this is the ground truth, not a metric that might be aggregated away:

```bash
# cgroup v2 (modern kind nodes): nr_throttled / throttled_usec are the smoking gun
kubectl exec <pod> -- cat /sys/fs/cgroup/cpu.stat
# nr_periods 48211
# nr_throttled 18833      ← throttled in 39% of periods = you are CPU-limit-bound
# throttled_usec 91300000

# cgroup v1 (older): path differs
kubectl exec <pod> -- cat /sys/fs/cgroup/cpu/cpu.stat
# nr_throttled 18833
# throttled_time 91300000000
```

If `nr_throttled / nr_periods` is more than a few percent on a latency-sensitive service, your CPU **limit** is too low — raise it or remove it.

> **The contrarian production stance:** many experienced SREs **set CPU requests but omit CPU limits entirely** on latency-sensitive services. The request still guarantees a fair share and drives scheduling; dropping the limit lets the pod use idle node CPU instead of being parked mid-request. You trade a little noisy-neighbour risk for a lot less tail latency. Memory limits stay (incompressible — you must cap them), but CPU limits are the one knob where "unlimited" is often the right call. This was a real, measurable win on a service I profiled: p99 dropped ~40% the moment the CPU limit came off, with no change in average usage.

---

## LimitRange & ResourceQuota — guardrails at the namespace boundary

Individual manifests drift. The way you enforce resource hygiene at scale is two namespace-scoped objects that admission control applies to *everyone* in the namespace. They do different jobs and are frequently confused.

```
  ┌─ LimitRange ───────────────────────┐   ┌─ ResourceQuota ──────────────────┐
  │ PER-OBJECT rules (per container/pod)│   │ NAMESPACE-WIDE TOTALS (the sum)  │
  │  • default requests/limits if unset │   │  • Σ requests.cpu ≤ X            │
  │  • min / max per container          │   │  • Σ limits.memory ≤ Y           │
  │  • max request:limit ratio          │   │  • count of pods/services/pvcs   │
  │  → mutates + validates each object  │   │  → rejects the Nth object        │
  └─────────────────────────────────────┘   └───────────────────────────────────┘
      "no single pod may be huge/tiny"          "this team may not exceed its slice"
```

**`LimitRange`** operates per-object as a pod is admitted. Its most useful power is **defaulting**: it injects `requests`/`limits` into containers that forgot them — which quietly rescues every BestEffort pod a developer would otherwise ship:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: sane-defaults
  namespace: dojo-quota
spec:
  limits:
    - type: Container
      default:            # becomes the container's LIMIT if it sets none
        cpu: 500m
        memory: 256Mi
      defaultRequest:     # becomes the container's REQUEST if it sets none
        cpu: 100m
        memory: 128Mi
      max:                # reject any container asking for more than this
        cpu: "2"
        memory: 1Gi
      min:                # reject any container asking for less than this
        cpu: 10m
        memory: 16Mi
      maxLimitRequestRatio:   # limit may be at most 4x the request (bounds oversubscription)
        cpu: "4"
```

**`ResourceQuota`** caps the *aggregate* for the whole namespace. The gotcha that generates the most support tickets: **once a quota sets any `requests.*` or `limits.*`, every pod in that namespace MUST declare the matching field, or admission rejects it.** A quota on `requests.cpu` turns "forgot to set a CPU request" from a silent BestEffort pod into a hard `forbidden` error at apply time. This is why you almost always pair a `ResourceQuota` with a `LimitRange` that provides defaults — otherwise you break every bare manifest in the namespace.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-slice
  namespace: dojo-quota
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "20"
    count/services.loadbalancers: "2"
```

Inspect live quota consumption — the `Used / Hard` columns are what you watch before a big rollout:

```bash
kubectl -n dojo-quota get resourcequota team-slice -o jsonpath='{.status.used}{"\n"}'
kubectl -n dojo-quota describe resourcequota team-slice   # human-readable Used vs Hard table
```

---

## Right-sizing from metrics — kill the superstition

Most manifests are sized by copy-paste and vibes. The disciplined loop is: **measure the real P95/P99 of actual usage, set the request near typical usage, set the memory limit at a safe headroom above the peak, and leave CPU limits generous or absent.** Over-requesting silently wastes capacity (the scheduler fences off memory nobody uses); under-requesting invites eviction and noisy-neighbour starvation.

The rules of thumb that hold up in production:

| Resource | Set the **request** to | Set the **limit** to |
|----------|------------------------|----------------------|
| **CPU** | ~P90 of observed steady-state usage (your fair-share floor) | Generous, or **omit** for latency-sensitive services (avoid CFS throttling) |
| **Memory** | ~P95 of observed working set (what you need to not be evicted) | Just above true peak incl. GC headroom — this is a hard **kill** line, size it with care |

Pull the real numbers. `kubectl top` is the instant view; your Prometheus/Mimir pipeline is the historical truth:

```bash
# instant, needs metrics-server
kubectl top pods -n dojo-quota --containers --sort-by=memory
kubectl top pods -n dojo-quota --sort-by=cpu

# what you actually requested vs what the node reports is committed
kubectl describe node dojo-worker | sed -n '/Allocated resources/,/Events/p'
```

The historical queries you'd run against your LGTM/Prometheus stack to size honestly — percentiles over a representative week, not an average over an hour:

```promql
# P95 working-set memory per pod over 7d — size the memory REQUEST near this
quantile_over_time(0.95,
  container_memory_working_set_bytes{namespace="dojo-quota", container!=""}[7d])

# P90 CPU over 7d — size the CPU REQUEST near this
quantile_over_time(0.90,
  rate(container_cpu_usage_seconds_total{namespace="dojo-quota", container!=""}[5m])[7d:])

# how often are you throttled? if high, your CPU LIMIT is the bottleneck, not CPU itself
rate(container_cpu_cfs_throttled_periods_total{namespace="dojo-quota"}[5m])
  / rate(container_cpu_cfs_periods_total{namespace="dojo-quota"}[5m])
```

> **VPA in recommender mode is the honest shortcut.** You don't have to eyeball percentiles forever. Run the Vertical Pod Autoscaler with `updateMode: "Off"` and it watches real usage and *recommends* requests/limits without touching your pods — a data-driven right-sizing proposal you can read with `kubectl describe vpa <name>` and apply at your own pace. (Never run VPA in `Auto` mode on the *same* workload as an HPA keyed on CPU/memory — they fight: the HPA scales replicas out on the very signal the VPA is trying to shrink, and they oscillate.)

---

## Debugging resource & QoS problems

Four failure modes cover the overwhelming majority of real resource incidents. Diagnose in order of cheapest signal; the golden rule for `kind` still applies — **when `kubectl` runs out of answers, drop to `docker exec` into the node**, because every node is a container and the cgroup truth lives there.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Pod `CrashLoopBackOff`, last state `OOMKilled`, exit code `137` | Container exceeded its **own** `limits.memory` (heap/working set grew past the cap) | Raise `limits.memory` to true-peak + headroom, or fix the leak/heap setting; confirm with `lastState.terminated.reason` |
| Pod `Evicted` (`status.reason: Evicted`), rescheduled elsewhere | **Node** memory pressure; kubelet evicted a low-QoS / over-request pod proactively | Raise the pod's memory **request** (improves its OOM score + eviction rank); reduce node oversubscription; check `kubectl describe node` pressure conditions |
| Service slow / high p99, but `kubectl top` shows low CPU% and **no** restarts | **CFS CPU throttling** — bursty demand hits the per-100ms quota | Raise or remove `limits.cpu`; confirm via `cpu.stat` `nr_throttled`; consider request-only on latency-sensitive pods |
| Pod stuck `Pending`, `describe` says `FailedScheduling: Insufficient cpu/memory` | Sum of **requests** doesn't fit any node's allocatable (requests too high, or node genuinely full) | Lower the pod's **requests**, add/resize nodes, or clear a node; remember limits are irrelevant to fit |
| `kubectl apply` → `error ... exceeded quota` or `must specify requests.cpu` | `ResourceQuota` would be exceeded, or a quota requires a field your manifest omits | Check `describe resourcequota` Used/Hard; add the missing request/limit (or add a `LimitRange` to default it) |

### Diagnose each — the exact commands

**`OOMKilled` (your own limit).** The exit code and `lastState` are the ground truth — a `CrashLoopBackOff` alone doesn't tell you *why*:

```bash
kubectl get pod <name> -o jsonpath='{range .status.containerStatuses[*]}{.name}{" lastState="}{.lastState.terminated.reason}{" exit="}{.lastState.terminated.exitCode}{"\n"}{end}'
# app lastState=OOMKilled exit=137
kubectl get pod <name> -o jsonpath='{.spec.containers[0].resources.limits.memory}{"\n"}'   # what you capped it at
kubectl describe pod <name> | grep -iE 'oom|restart|last state'
```

137 = `128 + 9 (SIGKILL)`. If the node had free memory (`kubectl top node`) this is a *self* OOM — your limit, not node pressure. Raise the limit or shrink the heap (`-Xmx`, `GOMEMLIMIT`, `--max-old-space-size`).

**Eviction (node pressure).** Evicted pods leave a tombstone object explaining the reason; the node carries the pressure condition:

```bash
kubectl get pods -A --field-selector=status.phase=Failed    # evicted tombstones
kubectl get pod <name> -o jsonpath='{.status.reason}: {.status.message}{"\n"}'
# Evicted: The node was low on resource: memory. Container app was using 612Mi, request was 128Mi.
kubectl describe node dojo-worker | grep -A6 Conditions        # MemoryPressure True?
docker exec dojo-worker sh -c 'cat /proc/meminfo | head -3'     # node-level truth
```

Note the message names the culprit: *using 612Mi, request was 128Mi* — the undersized request is exactly what made this pod the eviction target.

**CPU throttling.** The one that hides from `kubectl top`. Go straight to the cgroup counters:

```bash
kubectl exec <pod> -- cat /sys/fs/cgroup/cpu.stat        # cgroup v2
# nr_periods / nr_throttled → ratio is your throttle rate
kubectl get pod <name> -o jsonpath='{.spec.containers[0].resources.limits.cpu}{"\n"}'   # the ceiling causing it
# if nr_throttled/nr_periods > ~0.05 on a latency-sensitive svc, the CPU LIMIT is the problem
```

**`Pending` on insufficient resources.** The event tells you which dimension and by how much; then compare against what each node can actually offer:

```bash
kubectl describe pod <name> | sed -n '/Events:/,$p'
# Warning FailedScheduling: 0/3 nodes are available: 3 Insufficient memory.
kubectl get pod <name> -o jsonpath='{.spec.containers[*].resources.requests}{"\n"}'
for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "== $n =="; kubectl describe node "$n" | sed -n '/Allocated resources/,/Events/p'
done
```

If every node shows requests near allocatable, the cluster is genuinely full — lower the request or add capacity. If not, you asked for more than any single node has (requests don't spread across nodes).

**Quota rejection.** Admission tells you the exact field and the arithmetic:

```bash
kubectl -n dojo-quota describe resourcequota        # Used vs Hard, line by line
kubectl -n dojo-quota apply -f pod.yaml
# Error: pods "x" is forbidden: exceeded quota: team-slice,
#   requested: requests.memory=2Gi, used: requests.memory=7Gi, limited: requests.memory=8Gi
```

If the error is `must specify requests.cpu` rather than `exceeded quota`, the namespace has a quota but no defaulting `LimitRange` — add the request to the manifest or install a `LimitRange`.

> **War story.** We had a Go service at SAP that was `OOMKilled` roughly once a day, always between 02:00 and 03:00. The limit was 512Mi; `kubectl top` showed a steady ~300Mi working set, so it looked like comfortable headroom and three different people had already "ruled out memory." The killer was the nightly batch job: it streamed a large result set and Go's garbage collector, with no `GOMEMLIMIT` set, happily let the heap balloon toward the *container* limit before collecting — a classic "the GC targets available memory, and the container lied to it about how much that was." The working-set average hid a sharp, short peak that the 15s `kubectl top` scrape never caught, but `container_memory_working_set_bytes` at 1s resolution in Mimir showed a clean spike straight into the 512Mi wall every night. Two-line fix: set `GOMEMLIMIT=448MiB` so the GC collected *before* the kernel did, and raised the limit to 640Mi for headroom. Zero OOMs since. The lesson: **an average is not a peak, a runtime's idea of "available memory" is not your container limit unless you tell it, and the metric resolution that clears a suspect can be the very thing hiding the smoking gun.**

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. State what the **scheduler** reads (requests) vs what the **kernel/kubelet** enforces (limits), and why a pod can "fit" on a node it will then be OOM-killed on.
2. Explain why CPU is *compressible* (throttled) and memory is *incompressible* (killed), and what that asymmetry implies for setting their limits.
3. Derive the three QoS classes from requests/limits, and name which is evicted first and which last under node memory pressure.
4. Explain how a Burstable pod's memory **request** changes its `oom_score_adj`, and why an undersized request is a death sentence under pressure.
5. Describe CFS bandwidth control in terms of quota-per-100ms-period, and explain how a pod at 30% average CPU can still be throttled on every request.
6. Read `cpu.stat` `nr_throttled`/`nr_periods` and decide whether to raise or remove a CPU limit.
7. State the difference between a `LimitRange` (per-object defaults/bounds) and a `ResourceQuota` (namespace totals), and why a quota usually needs a `LimitRange` beside it.
8. Tell `OOMKilled` (exit 137, self-limit) apart from `Evicted` (node pressure) from the pod's status fields alone.
9. Right-size a workload from P95 memory / P90 CPU, and say when you'd omit the CPU limit entirely.

➡ Next up: **Module 03 — Zero-Downtime Rollouts & Rollbacks**, where these QoS and readiness fundamentals become the difference between a seamless deploy and a self-inflicted outage.
