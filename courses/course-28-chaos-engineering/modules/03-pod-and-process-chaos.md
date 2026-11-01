# Pod & Process Chaos

> **Module 03 · Course 28** — Pod kills and OOM events are the most frequent real-world Kubernetes faults, yet most teams have never verified their system actually handles them gracefully. This module covers what *actually happens* inside Kubernetes when a pod dies, and how to inject these faults to confirm your resilience properties hold.

You know from Module 01 how to design an experiment. You know from Module 02 that crash faults are fail-stop and the easiest to detect. Now let's put them in the cluster and watch the reconciler respond.

---

## What actually happens when you kill a pod

When you run `kubectl delete pod`, the sequence is longer than most engineers realize:

```
 1. API server marks pod for deletion (sets .metadata.deletionTimestamp)
 2. Endpoint controller removes pod IP from Service Endpoints
    → in-flight requests complete; new requests stop being routed here
 3. kubelet sends SIGTERM to PID 1 in the container (graceful period starts)
 4. App handles SIGTERM: drains connections, flushes state, exits cleanly
 5. After terminationGracePeriodSeconds (default: 30s), kubelet sends SIGKILL
 6. Container exits; kubelet reports status to API server
 7. Pod object is garbage-collected
 8. ReplicaSet controller notices: actual < desired → creates a replacement pod spec
 9. Scheduler places the new pod on a node
10. kubelet pulls the image (cached: ~0s; cold: up to 90s for a large image)
11. readinessProbe starts running; pod transitions to Ready
12. Endpoint controller adds new pod IP to Service Endpoints
    → traffic flows again
```

Steps 2 and 12 are the traffic gates. Between them the pod is out of rotation. The gap between step 7 and step 12 is the **recovery window** — the duration your cluster runs at reduced capacity.

```bash
# Watch the full lifecycle in two terminals:
# Terminal 1 - live pod watch:
kubectl get pods -n dojo-chaos-pod -w

# Terminal 2 - inject:
kubectl delete pod -n dojo-chaos-pod $(kubectl get pod -n dojo-chaos-pod -l app=web -o name | head -1 | cut -d/ -f2)
```

Typical recovery window breakdown:
| Step | Typical duration |
|------|-----------------|
| Scheduler placement | 0.5–2s |
| Image pull (cached) | ~0s |
| Image pull (cold, 200MB image) | 30–90s |
| `initialDelaySeconds` on readinessProbe | as configured |
| Probe period × success threshold | e.g., 2s × 1 = 2s minimum |

This is why image pre-pulling, tagging (not `:latest`), and tight readiness probe parameters matter for recovery time SLOs.

---

## PodDisruptionBudgets under chaos

PDBs protect against *voluntary* disruptions. They do not protect against involuntary kill-9-style failures.

```
Voluntary disruptions (PDB applies):
  kubectl drain, rolling update, eviction API, node auto-provisioner scale-down

Involuntary disruptions (PDB does NOT apply):
  node failure, OOM kill, kernel panic, disk full, SIGKILL from kubelet
```

In a chaos experiment using `kubectl delete pod`, the disruption is voluntary — the PDB is your first line of defense. Verify it actually works:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
  namespace: dojo-chaos-pod
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: web
```

With 3 replicas and this PDB:
1. `kubectl drain <node>` → tries to evict pod-1
2. PDB check: 3 pods Running, 3 >= minAvailable+1? Yes → eviction allowed
3. pod-1 evicted; 2 pods remain
4. `kubectl drain` → tries to evict pod-2
5. PDB check: 2 pods Running, 2 >= minAvailable+1? No (2 < 3) → eviction **blocked**

```bash
# Check PDB status — ALLOWED DISRUPTIONS = 0 means the PDB is actively protecting:
kubectl get pdb -n dojo-chaos-pod
# NAME      MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
# web-pdb   2               N/A               1                     5m

# Confirm the selector matches the pods:
kubectl get pdb web-pdb -n dojo-chaos-pod -o jsonpath='{.spec.selector.matchLabels}'
kubectl get pods -n dojo-chaos-pod -l app=web --show-labels
```

A PDB with `minAvailable: 0` or `maxUnavailable: 100%` passes `kubectl apply` without error and does absolutely nothing. Verify the `ALLOWED DISRUPTIONS` column, not just that the PDB object exists.

---

## Container restart vs pod reschedule

These are *not* the same event, and the distinction changes what your chaos experiment actually tests.

**Container restart** (kubelet-level):
- The container process exits; kubelet starts a new container on the same pod object, same node
- Pod name unchanged, pod IP unchanged (network namespace is preserved)
- Triggered by: liveness probe failure, non-zero exit code, OOM kill
- Governed by `restartPolicy`: `Always`, `OnFailure`, `Never`
- Subject to exponential backoff: 10s → 20s → 40s → 80s → 160s → 300s cap

**Pod reschedule** (scheduler-level):
- Pod object is deleted; a new pod object is created
- New pod name, new pod IP, potentially different node
- Triggered by: `kubectl delete pod`, node failure, eviction, rolling update
- Subject to all scheduling constraints: `nodeAffinity`, `topologySpreadConstraints`, resource requests

```bash
# Container restart: same pod name, increments restartCount
kubectl exec -n dojo-chaos-pod <pod> -- kill 1    # triggers restart, not reschedule
kubectl get pod <pod> -n dojo-chaos-pod \
  -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'

# Pod reschedule: new pod name, possibly new node
kubectl delete pod -n dojo-chaos-pod <pod>
kubectl get pods -n dojo-chaos-pod -o wide        # new pod, potentially new node
```

Why the distinction matters for chaos experiments:
- A container restart does **not** exercise scheduling constraints — the pod stays on the same node, even if `topologySpreadConstraints` would place it elsewhere for a fresh pod
- A container restart does **not** exercise image pull (image is already in the node's image store)
- A pod reschedule exercises the full scheduling and startup path, including cold pulls and topology constraints

If you want to verify that your topology spread actually works, delete the pod — don't crash the container.

---

## Liveness and readiness interplay during failure

These two probes have distinct failure semantics that interact in non-obvious ways under chaos:

| Probe | Failure action | Purpose |
|-------|---------------|---------|
| `readinessProbe` | Remove pod from Service Endpoints (traffic stops) | Signal "I can't serve right now, but I may recover" |
| `livenessProbe` | Kill and restart the container | Signal "I am stuck and need to be restarted" |

**Readiness probe timing under chaos.** When you delete a pod, the Endpoint controller removes it from Service Endpoints. But if the *other* pods in the Deployment have slow readiness probes, there's a window where the remaining pods are still considered Ready but are actually under increased load. The probe doesn't re-check until its next `periodSeconds` tick.

```bash
# Check probe configuration for the whole Deployment:
kubectl get deploy web -n dojo-chaos-pod \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}'

# A period of 10s and failureThreshold of 3 means 30s of traffic while broken.
# For chaos experiments, tighten to: periodSeconds: 2, failureThreshold: 2 = 4s window.
```

**Liveness probe interference with graceful shutdown.** The liveness probe continues running during the `terminationGracePeriodSeconds` window. If your app is intentionally closing connections during SIGTERM handling, the liveness probe may fire, see a "not healthy" response, and restart the container — interrupting the graceful shutdown.

```yaml
# Prevent liveness probe from firing during shutdown (Kubernetes 1.27+):
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  periodSeconds: 10
  failureThreshold: 3
  terminationGracePeriodSeconds: 5   # overrides pod-level for this probe only
```

On older clusters (< 1.27), the workaround is making the `/healthz` endpoint return 200 during graceful shutdown and only fail *after* SIGKILL would have been sent anyway.

**OOM kill and readiness.** When a container is OOM-killed (exit code 137), the container restarts. While it's restarting, the readiness probe fails and the pod drops out of Endpoints. After the container comes back up, the probe needs to pass before traffic is re-routed. If you're not watching `restartCount`, an OOM loop can look like "occasionally slow" rather than "constantly restarting."

```bash
# Spot an OOM loop instantly:
kubectl get pod <pod> -n dojo-chaos-pod \
  -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'
kubectl get pod <pod> -n dojo-chaos-pod \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
# -> OOMKilled

# Exit code 137 confirms SIGKILL (128 + 9):
kubectl get pod <pod> -n dojo-chaos-pod \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
# -> 137
```

---

## OOM and crashloop injection

### Memory pressure via resource limits

The simplest OOM injection is tightening the memory limit below what the workload needs:

```bash
# Reduce memory limit to trigger OOMKill:
kubectl set resources deploy/web -n dojo-chaos-pod --limits=memory=5Mi

# Watch the pod enter an OOM loop:
kubectl get pods -n dojo-chaos-pod -w
# STATUS: OOMKilled → CrashLoopBackOff

# Restore a sane limit:
kubectl set resources deploy/web -n dojo-chaos-pod --limits=memory=128Mi
```

### Controlled memory stress via a sidecar

For injecting memory pressure without changing the application's own limits, use a stress sidecar. Pin the image to a tag:

```yaml
# Add to spec.template.spec.containers (remove after experiment):
- name: mem-stressor
  image: polinux/stress:1.0.4
  command: ["stress"]
  args: ["--vm", "1", "--vm-bytes", "200M", "--timeout", "60s"]
  resources:
    requests:
      memory: "50Mi"
    limits:
      memory: "256Mi"
```

The sidecar and the main container share the pod's memory cgroup. As the stressor consumes memory, it reduces what's available to the main container. Set the pod-level limit to control the total OOM threshold.

### CrashLoopBackOff mechanics

When a container crashes repeatedly, kubelet applies exponential backoff before each restart:

```
Restart 1: immediate
Restart 2: wait 10s
Restart 3: wait 20s
Restart 4: wait 40s
Restart 5: wait 80s
Restart 6: wait 160s
Restart 7+: wait 300s (5-minute cap, repeated)
```

At steady state, a crashlooping pod attempts a restart every 5 minutes. During a real incident, if you fix the underlying issue but the pod is mid-backoff, it won't recover for up to 5 more minutes. Force an immediate retry:

```bash
# Delete the crashlooping pod — the ReplicaSet creates a new pod with restart count 0:
kubectl delete pod -n dojo-chaos-pod <crashlooping-pod>
# The replacement starts immediately, fresh backoff counter.
```

Confirm the new pod has no backoff by checking `restartCount` immediately after creation:

```bash
kubectl get pod -n dojo-chaos-pod -l app=web \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}'
```

---

## Debugging pod and process chaos

### Slow recovery

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Replacement pod takes 90+ seconds to serve traffic | Image not cached on the target node; cold pull dominates the recovery window | Pre-pull images with a DaemonSet or `kind load docker-image`; always pin to a tag already cached on every node |
| Pod shows Ready but traffic still fails for 10–30s after a kill | Old connection from the load balancer is still routed to the terminating pod; TCP connection draining is incomplete | Ensure `terminationGracePeriodSeconds` > the load balancer's connection drain window; set `preStop: exec: sleep 5` to give the LB time to stop routing |
| PDB blocks the chaos experiment (drain can't complete in reasonable time) | `minAvailable` = replica count — there is no allowed disruption | PDB is working correctly; either reduce `minAvailable` by 1 for the experiment, or increase replica count before running the experiment |
| Recovery is faster in the dojo than on a real incident | Kind nodes have images pre-cached; prod nodes may not; real load is absent | Use realistic image sizes in dojo tests; add a background load generator during chaos experiments to expose thread/connection pool pressure |

### Thundering herd on restart

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| After 3 pods restart simultaneously, all downstream services spike in errors | All pods reconnect to the DB at the same instant; the connection pool is overwhelmed for 5–10s | Stagger startup: use `initialDelaySeconds` jitter in the readiness probe, or add a `preStart` hook with `sleep $(( RANDOM % 10 ))`; cap connection pool size per pod |
| After pod kill, HPA scales up 5 new pods; all fail immediately | Scaling + cold start race: new pods hit the DB before it can absorb the connection burst | Set `startupProbe` to block traffic during warm-up; gate connection establishment with a circuit breaker |
| A pod that was OOM-killed comes back and immediately re-OOMs | Memory limit is set below the workload's baseline requirement — the OOM is not a spike | Profile memory baseline under realistic load; set `limits.memory` to at least 1.5× the measured baseline; never set `limits.memory` < `requests.memory` |

> **War story.** On a load test before a service launch, I ran a pod-delete loop (deleting one pod every 30s from a 5-replica Deployment) while `wrk` ran a sustained load test. The first 10 minutes were clean — error rate held at 0. At minute 11 it jumped to 18%. Every pod had a `restartCount` of 2–3 — they were being OOM-killed by memory pressure from the load test, *independently* of the delete loop. When all five pods happened to restart within the same 10-second window, they simultaneously opened new PostgreSQL connections. Postgres hit its `max_connections` limit, and every new connection attempt got `FATAL: sorry, too many clients`. The thundering herd was invisible in isolation testing. It only appeared when chaos (the delete loop causing extra restarts) combined with load. The fix: raise `memory.limit` from 256Mi to 512Mi, and set `PG_POOL_MAX_CONNECTIONS=10` per pod. The lesson: chaos experiments must run *under realistic load*, not in a quiet cluster.

---

## Checkpoint

You're ready for network chaos when you can, without looking anything up:

1. List the 12 steps of pod termination and replacement, and identify the two steps that gate traffic flow.
2. Explain the difference between a container restart and a pod reschedule, and give one scenario where the distinction changes what the chaos experiment tests.
3. Describe what PDB `minAvailable: 2` does during a `kubectl drain` with 3 replicas — step through the eviction check sequence.
4. State the CrashLoopBackOff backoff schedule from restart 1 through restart 7, and give the command to reset it without waiting.
5. Explain what exit code 137 means, and write the two `jsonpath` commands that confirm a pod was OOM-killed.
6. Describe a thundering-herd scenario triggered by simultaneous pod restarts, and name three mechanisms that prevent it.
7. What happens to liveness probes during graceful shutdown, and why does this matter for correctness?

➡ Next up: **Network Chaos** — crash faults are the easy ones. Network faults (latency, loss, partitions) are where most real incidents start and where chaos experiments deliver the highest signal-to-noise ratio.
