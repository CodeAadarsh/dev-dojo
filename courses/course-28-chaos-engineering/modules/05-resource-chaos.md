# Resource Chaos

> **Module 05 · Course 28** — The most common real-world chaos isn't a dramatic network partition; it's a noisy neighbor eating your CPU slice, a runaway container filling the disk, or the kubelet quietly evicting your pod under memory pressure while your metrics look green. Resource chaos is insidious because it degrades before it crashes — and degraded is harder to catch than dead.

You already know how to set `requests` and `limits`. This module goes deeper: why the QoS class determines who gets killed first, how CPU throttling silently adds latency without crashing anything, and how limits, PDBs, and probes interact when the node is under real pressure.

---

## QoS Classes and Eviction Order

Kubernetes assigns every Pod one of three QoS classes based purely on its resource spec. The kubelet uses this class — not pod priority — to decide which pods get evicted first when the node is short on memory.

| QoS Class | Condition | Eviction priority |
|-----------|-----------|-------------------|
| **BestEffort** | No `requests` or `limits` on any container | Evicted first |
| **Burstable** | `requests` set but `requests < limits`, or only limits set | Evicted second |
| **Guaranteed** | `requests == limits` on every resource, every container | Evicted last |

```bash
# Read the QoS class the kubelet assigned:
kubectl get pod <name> -o jsonpath='{.status.qosClass}{"\n"}'
```

The kubelet runs a continuous eviction loop against configurable thresholds. When a node crosses `--eviction-hard memory.available<100Mi` (the default), it starts evicting:

```
Eviction order when node memory is exhausted
────────────────────────────────────────────
1. BestEffort pods           ← no mercy, no negotiation
2. Burstable pods            ← evicted in order of (usage - request), largest first
3. Guaranteed pods           ← only when the kubelet can't avoid it
```

A pod you never gave a `limit` to can silently vanish during a neighbor's memory spike. You won't see an OOMKilled exit code. You'll see status `Evicted` and a cold restart on a different node, and if you weren't watching you'll miss it entirely.

> **Practical rule.** Every pod that matters in production gets both `requests` and `limits`. Set `requests == limits` for stateful pods you can't lose (Guaranteed). Set `requests` slightly below `limits` for services where burst is acceptable but you want OOM protection (Burstable). BestEffort is only acceptable for throwaway jobs that can fail and retry freely.

---

## CPU Throttling — Latency Without a Crash

CPU is *compressible*: exceeding a CPU limit does not kill the container; it throttles it. The Linux kernel's CFS (Completely Fair Scheduler) bandwidth controller enforces limits by suspending the container's processes when the quota for its accounting period is exhausted.

```
CFS period = 100ms (default)
quota      = cpu_limit × period
             e.g., 0.5 cores × 100ms = 50ms of CPU per 100ms window

If the container uses 50ms in the first 40ms of the period,
it is FROZEN for the remaining 60ms:

  t=0ms    t=40ms                t=100ms   t=140ms
  ├─ RUN ──┤◄────── FROZEN ──────►├─ RUN ──►...
```

Result: tail latency spikes. A p99 that is 3× the p50 with no error increase is often CPU throttling, not a slow database. The container is alive, liveness probes pass, Deployment shows `Ready` — but requests queue during the frozen windows and never finish within the SLO.

```bash
# Confirm throttling on a running container — read directly from cgroup:
kubectl exec -n dojo-chaos <pod> -- cat /sys/fs/cgroup/cpu/cpu.stat
# Key fields:
#   nr_throttled N       — how many 100ms periods were throttled
#   throttled_time N     — nanoseconds the container spent frozen

# Compute the throttle ratio manually:
# throttled_time / (nr_periods × period_ns)

# If you have kube-state-metrics + Prometheus:
# container_cpu_cfs_throttled_periods_total / container_cpu_cfs_periods_total
# A ratio > 0.25 is worth investigating; > 0.5 is a problem.
```

The fix is rarely "raise the limit to infinity." Profile the workload under realistic load, set the limit high enough that burst periods complete within a CFS window, and track the throttle ratio as a dashboard signal — not just CPU utilisation.

> **Protip.** For latency-sensitive services where raising limits isn't an option (multi-tenant cost controls), consider tuning `--cpu-cfs-quota-period` on the kubelet to a shorter value (e.g., 5ms). Shorter periods mean smaller quota windows and more frequent CPU slice opportunities — the container never freezes as long. The tradeoff is higher scheduler overhead; benchmark before committing.

---

## Memory Pressure — OOM Kill vs Kubelet Eviction

Two different parts of the system can kill a container for memory, and they leave different forensic signatures:

| Who | Trigger | Victim | Pod fate |
|-----|---------|--------|----------|
| **Kernel OOM killer** | Container hits its cgroup memory `limit` | The offending process | Container restarts; Pod stays (`OOMKilled`) |
| **Kubelet eviction manager** | Node-wide memory threshold crossed | Lowest-priority pods (BestEffort first) | Pod terminated and rescheduled; new pod on another node |

```bash
# Container killed by cgroup OOM → exit reason is OOMKilled:
kubectl get pod <name> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
# -> OOMKilled
# -> exit code 137 (128 + SIGKILL)

# Pod evicted by the kubelet:
kubectl get pod <name> -o jsonpath='{.status.reason}{"\n"}'
# -> Evicted

kubectl describe pod <name> | grep -A5 "message:"
# -> The node was low on resource: memory.
#    Threshold quantity: 100Mi, available: 88Mi.
```

The two failure modes need entirely different fixes:
- **OOMKilled** → raise the container's memory `limit`, or fix the memory leak. Use `kubectl top pod --containers` to confirm the working set is actually approaching the limit.
- **Evicted** → the pod was a victim of a neighbor's spike. The fix is adding `requests` (so the pod isn't BestEffort), spreading replicas across nodes, or adjusting the eviction threshold on the node.

### Soft vs Hard Eviction Thresholds

```
--eviction-hard   memory.available<100Mi   → evict immediately, no grace period
--eviction-soft   memory.available<300Mi   → warn; wait for --eviction-soft-grace-period
                  --eviction-soft-grace-period memory.available=90s
```

The gap between soft and hard threshold is where Guaranteed pods with a `terminationGracePeriodSeconds > 0` can finish in-flight requests before they're killed. BestEffort pods don't get this grace — they're gone the moment the hard threshold is crossed.

---

## IO Pressure and Disk-Full Crashes

Disk is the most overlooked resource. When a container's writable layer fills:

1. **App crashes** with `ENOSPC: no space left on device` — a write system call fails, Go/Java/Python panics or propagates the error, and the process exits.
2. **Kubelet's image GC** kicks in — it starts deleting unused image layers to reclaim space. If it can't recover enough, it sets `DiskPressure=True` on the node and begins evicting pods.

```bash
# Check node disk pressure:
kubectl describe node <node-name> | grep DiskPressure
# DiskPressure = True means evictions have started

# Check ephemeral storage usage per pod (requires metrics-server):
kubectl top pod <name> --containers

# Inside a kind node, check raw disk usage:
docker exec dojo-worker df -h /
```

### Ephemeral Storage Limits

Every container can declare `ephemeral-storage` limits. This covers the container's writable layer + emptyDir volumes (not PVCs):

```yaml
resources:
  requests:
    ephemeral-storage: "100Mi"
  limits:
    ephemeral-storage: "500Mi"
```

When a container exceeds its ephemeral-storage limit, the kubelet evicts the pod immediately — no OOMKill signal, no graceful termination. The QoS-based eviction order does not apply here; the per-container limit is checked independently.

> **Container log accumulation.** The kubelet rotates container logs automatically (configurable via `--container-log-max-size` and `--container-log-max-files`), but a pod that writes to its writable layer directly — not stdout — bypasses this rotation and can fill disk silently. If your app writes large files anywhere under `/` inside the container (not a mounted PVC), add an `ephemeral-storage` limit.

---

## Noisy Neighbors

On a shared node, one pod's resource burst affects every other pod scheduled there:

```
Node: 4 cores, 8 GB RAM
───────────────────────────────────────────────────
Pod A  limit=2 CPU    spikes to limit:  ████████████████░░░░
Pod B  limit=1 CPU    Guaranteed:       ████████░░░░░░░░░░░░  ← CFS squeezes it during A's burst
Pod C  no limits      BestEffort:       ████░░░░░░░░░░░░░░░░  ← gets whatever's left
```

CPU limits bound the blast radius on CPU (Pod A can't exceed 2 cores). Memory is different: if Pod A has a Burstable class and grows toward its limit, Pod C (BestEffort) is evicted first, even if Pod C wasn't the problem.

**The multi-layer defence:**

```yaml
# LimitRange: enforce requests on every container in the namespace
apiVersion: v1
kind: LimitRange
metadata:
  name: chaos-defaults
  namespace: dojo-chaos
spec:
  limits:
    - type: Container
      defaultRequest:
        cpu: "100m"
        memory: "64Mi"
      default:
        cpu: "500m"
        memory: "256Mi"
      max:
        cpu: "2"
        memory: "1Gi"
```

```yaml
# ResourceQuota: cap total namespace consumption
apiVersion: v1
kind: ResourceQuota
metadata:
  name: chaos-quota
  namespace: dojo-chaos
spec:
  hard:
    requests.cpu: "4"
    requests.memory: "4Gi"
    limits.cpu: "8"
    limits.memory: "8Gi"
    pods: "20"
```

A `LimitRange` + `ResourceQuota` pair means no pod can run BestEffort in this namespace, and the whole namespace can't overrun the node.

---

## How Limits, PDBs, and Probes Compose Under Pressure

Each primitive does one job. Under resource pressure they interact — sometimes badly:

```
Node under memory pressure — kubelet eviction starts
                     │
     ┌───────────────▼───────────────┐
     │  PodDisruptionBudget          │
     │  blocks VOLUNTARY eviction    │  ← only voluntary (drain, autoscaler)
     │  if below minAvailable        │  ← involuntary eviction bypasses PDB
     └───────────────┬───────────────┘
                     │
     ┌───────────────▼───────────────┐
     │  readinessProbe fails         │
     │  → pod removed from Service   │  ← good: don't send traffic to a throttled pod
     │    endpoints during throttle  │
     └───────────────┬───────────────┘
                     │
     ┌───────────────▼───────────────┐
     │  livenessProbe timeout        │
     │  → container restarted        │  ← danger: restart under load worsens pressure
     │                               │    positive feedback loop possible
     └───────────────────────────────┘
```

**Critical nuance on PDBs and involuntary eviction.** PDBs only protect against *voluntary* disruptions: node drain, cluster upgrade, autoscaler scale-down. A node running out of memory is an *involuntary* event — the kubelet bypasses the PDB entirely. If you need to protect against that, use PodTopologySpreadConstraints to spread replicas across nodes so a single node's eviction storm can't take down a quorum.

**Liveness probe feedback loop under throttling.** If `timeoutSeconds` is too short (e.g., 1s) and the container is CPU-throttled, the probe HTTP call may not complete before the timeout — even though the app is running fine. The kubelet kills and restarts the container. The restart adds CPU pressure, which worsens throttling, which causes the next liveness check to fail sooner. Set `timeoutSeconds >= 3` for any service that might be CPU-throttled, and increase `failureThreshold` to absorb transient throttle spikes.

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 5       # 1s is too tight for a throttled container
  failureThreshold: 3     # 3 consecutive failures before restart
readinessProbe:
  httpGet:
    path: /ready
    port: 8080
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 2     # faster: stop sending traffic sooner
  successThreshold: 1
```

---

## Debugging Resource Chaos

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Pod restarts, exit code 137 | OOMKilled by cgroup memory limit | Raise memory `limit`; check for leaks with `kubectl top pod` |
| Pod status `Evicted` | Kubelet eviction — node memory pressure, probably BestEffort or high-usage Burstable | Add `requests`; check node pressure with `kubectl describe node` |
| p99 latency 3× p50, no errors, no crashes | CPU throttling | Read `cpu.stat` throttled_time; raise CPU `limit`; add throttle-ratio to dashboards |
| Pod `Pending`, `FailedScheduling: Insufficient memory` | `requests` exceed what any node has available | Reduce `requests` or scale out nodes; check `kubectl describe pod` events |
| App crashes with `ENOSPC` | Container hit ephemeral-storage limit, or node disk full | Add `ephemeral-storage` limits; check node with `docker exec <node> df -h /` |
| Liveness restarts every few minutes under load | Liveness `timeoutSeconds` too short vs CPU throttle | Increase `timeoutSeconds` to ≥3; check `nr_throttled` in `cpu.stat` |
| A healthy pod evicted during a neighbor's memory spike | Pod is BestEffort or all replicas are on one node | Set `requests`+`limits`; add PodTopologySpreadConstraints |
| `kubectl top node` shows 90% memory, pods look fine | Kubelet overhead, image layers, log files, emptyDir not captured by `top` | `docker exec <node> cat /proc/meminfo`; check kubelet `--eviction-hard` threshold |
| Node shows `DiskPressure=True`, random pod evictions | Image accumulation or log spam filling node disk | Check `docker exec <node> df -h`; add `ephemeral-storage` limits; tune kubelet GC |

> **War story.** At SAP we had a background ingestion job — no SLO, no alerting, labelled non-critical — running with no `requests` or `limits`. On a Friday afternoon it started a 10× spike in structured logging output, writing 4 GB to its writable container layer in 90 seconds. The kubelet hit `DiskPressure=True` on the node and began evicting pods in BestEffort order. The first victim was a different service entirely — one we'd assumed was on a different node. It was on the same node because the scheduler bin-packs by default, and with no `requests` the job had no cost signal, so it landed wherever the most free memory appeared to be. The 2 AM page wasn't about the job; it was about the service that went missing. We fixed it in two passes: `ephemeral-storage: 256Mi` limits on every pod in the namespace that morning, and a `LimitRange` the next sprint that made it impossible to run BestEffort in any namespace our team owns. The job has never triggered disk pressure since, and the service replica now has a PodTopologySpreadConstraint that keeps its pods on separate nodes. Unset resource requests are the silent technical debt of Kubernetes — you don't notice them until they're your Friday evening incident.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. State the three QoS classes and the eviction order the kubelet uses, and name the condition that determines each class.
2. Explain, mechanically, why CPU throttling causes latency spikes without crashing the container or triggering OOMKilled.
3. Distinguish between an OOMKilled container and an Evicted pod — including the exact `kubectl` commands and field paths to tell them apart.
4. Read a container's CPU throttle ratio from `/sys/fs/cgroup/cpu/cpu.stat` and explain what `nr_throttled` and `throttled_time` mean.
5. Describe the disk-full failure path: container log spam → `DiskPressure=True` → pod eviction.
6. Explain why a PDB does not protect a pod from involuntary (OOM) eviction, and what topology mechanism does.
7. Write a `LimitRange` that enforces minimum CPU and memory requests on every container in a namespace, preventing BestEffort pods.
8. Identify the liveness probe configuration that turns CPU throttling into a restart feedback loop, and state the fix.

➡ Next up: **GameDays & Experiment Tooling** — how to run a structured chaos experiment instead of hoping things break in a useful way.
