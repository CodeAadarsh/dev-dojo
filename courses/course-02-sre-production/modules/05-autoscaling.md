# Autoscaling: HPA, VPA & Cluster Autoscaler

> **Module 05 · Course 02** — There are exactly three axes along which Kubernetes can grow to meet demand, and a different controller owns each one. The **HPA** adds *more pods*. The **VPA** makes *each pod bigger*. The **Cluster Autoscaler** adds *more nodes* when the first two run out of room to place what they asked for. Confuse them — or wire two of them to fight over the same signal — and you get thrashing, stuck `<unknown>` metrics, and pods that scale up into a cluster with nowhere to put them. This module makes the three axes and their interactions concrete.

You wired a basic CPU HPA in the first challenge of this course. This module goes under the hood: the v2 metrics API, the scaling arithmetic, the `behavior` block that stops flapping, and the two autoscalers most people only hand-wave about. The pitch is "you already use an HPA; now understand why it does what it does at 2x load."

---

## The three axes — one picture

```
                 ┌─────────────────────────────────────────────┐
   HPA           │  replicas: 2 → 5      (MORE PODS)            │   autoscaling/v2
   horizontal    │   ▢ ▢   →   ▢ ▢ ▢ ▢ ▢                        │   needs: metrics-server
                 └─────────────────────────────────────────────┘
                 ┌─────────────────────────────────────────────┐
   VPA           │  requests: 100m → 600m   (BIGGER PODS)       │   needs: VPA operator
   vertical      │   ▢      →      ▣                            │   recreates pods
                 └─────────────────────────────────────────────┘
                 ┌─────────────────────────────────────────────┐
   Cluster       │  nodes: 3 → 5         (MORE NODES)           │   needs: cloud node groups
   Autoscaler    │   ■ ■ ■  →  ■ ■ ■ ■ ■                        │   (or Karpenter)
                 └─────────────────────────────────────────────┘
```

They chain: the **HPA** decides it wants more pods → the scheduler can't place them → they go `Pending` → the **Cluster Autoscaler** sees unschedulable pods and adds a node → the pods land. The HPA works on the *demand* signal; the CA works on the *placement* signal. The VPA sits orthogonal, right-sizing each pod's request so the other two have accurate numbers to reason about. Everything downstream depends on **requests** being set and sane.

---

## HPA v2: the metrics and the math

The HPA is a control loop that runs every ~15s (`--horizontal-pod-autoscaler-sync-period`). Each tick it reads a metric, compares it to a target, and computes a desired replica count from one deceptively simple formula:

```
                    ⎡              currentMetricValue  ⎤
 desiredReplicas =  ⎢ currentReplicas × ───────────────⎥   (ceil)
                    ⎢              desiredMetricValue   ⎥

 e.g. 3 pods running at 90% CPU, target 50%:
      ceil(3 × 90/50) = ceil(5.4) = 6 pods
```

Two consequences fall out of that formula and explain most HPA behavior:

- **It's proportional, not incremental.** The HPA doesn't "add one pod when busy." It jumps straight to the replica count that *should* bring the metric to target. A 4x overload scales ~4x in one step (bounded by `behavior`, below).
- **There's a tolerance deadband.** By default the HPA ignores ratios within `±10%` of target (the `horizontal-pod-autoscaler-tolerance`, default 0.1) — so a metric bouncing between 48% and 52% against a 50% target won't scale at all. This is the first line of defense against flapping.

### The four metric types

HPA v2 (`autoscaling/v2`) is not just CPU. There are four metric sources, and knowing which to reach for is the real skill:

| Type | Reads from | Target kinds | Classic use |
|------|-----------|--------------|-------------|
| `Resource` | metrics-server (`metrics.k8s.io`) | `Utilization` (% of request) or `AverageValue` | CPU / memory |
| `ContainerResource` | metrics-server | same as Resource, **per-container** | Sidecar-heavy pods where one container's CPU shouldn't drag the whole pod's number |
| `Pods` | custom metrics adapter (`custom.metrics.k8s.io`) | `AverageValue` (averaged across pods) | `http_requests_per_second` per pod |
| `Object` | custom metrics adapter | `Value` / `AverageValue` | A single object's metric, e.g. Ingress RPS |
| `External` | external metrics adapter (`external.metrics.k8s.io`) | `Value` / `AverageValue` | Cloud queue depth (SQS/Pub-Sub length), Kafka lag |

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web
  namespace: dojo-scale
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource               # 1) classic CPU utilization
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
    - type: Pods                   # 2) a custom per-pod metric (needs an adapter)
      pods:
        metric:
          name: http_requests_per_second
        target:
          type: AverageValue
          averageValue: "500"
    - type: External               # 3) scale on queue depth (needs an external adapter)
      external:
        metric:
          name: queue_messages_ready
          selector:
            matchLabels: {queue: "dojo-work"}
        target:
          type: AverageValue
          averageValue: "30"
```

> **Multiple metrics take the MAX.** When you list several metrics, the HPA computes a desired replica count *for each one independently* and uses the **largest**. That's the safe default — if either CPU or queue depth says "scale up," you scale up. It also means one misconfigured metric returning a huge value can dominate and over-scale, so test each metric in isolation first.

### `Utilization` needs a request — this is the #1 gotcha

`averageUtilization: 60` means "60% of the pod's CPU **request**." The request is the *denominator*. If the container has no CPU request, there is no denominator, and the HPA reports the metric as `<unknown>` forever and never scales. This is the single most common HPA failure and it is a spec problem, not a metrics problem:

```bash
kubectl -n dojo-scale get hpa web
# NAME   REFERENCE        TARGETS         MINPODS   MAXPODS   REPLICAS
# web    Deployment/web   <unknown>/60%   2         10        2        ← <unknown> = no denominator or no metrics-server
```

If you want to scale on absolute usage with no request set, use `AverageValue` (e.g. `averageValue: 200m`) instead of `Utilization` — but setting proper requests and using `Utilization` is the right answer almost always.

---

## metrics-server: the thing that feeds `Resource` metrics

`Resource`/`ContainerResource` metrics come from **metrics-server**, a cluster add-on that scrapes each kubelet's `/metrics/resource` endpoint and serves the aggregated `metrics.k8s.io` API. It powers both `kubectl top` and every CPU/memory HPA. It is **not installed by default** on kind.

On kind specifically, the kubelet's serving certificate is self-signed, so metrics-server must be told to skip TLS verification or it sits `NotReady` forever. The dojo ships a one-liner that handles exactly this:

```bash
bash labs/bootstrap/install-metrics-server.sh
```

That script applies the upstream manifest and patches in `--kubelet-insecure-tls` (the kind-specific fix), then waits for rollout. Give it ~30s to collect a scrape window, then:

```bash
kubectl top nodes
kubectl top pods -A
kubectl get apiservice v1beta1.metrics.k8s.io   # must show AVAILABLE=True
```

```
  kubelet /metrics/resource  ──scrape every 15s──▶  metrics-server
                                                         │  serves metrics.k8s.io
                          ┌──────────────────────────────┼──────────────────────┐
                          ▼                               ▼                       ▼
                   kubectl top                    HPA controller          VPA recommender
                                                (Resource metrics)       (historical usage)
```

**Custom and external metrics need a different component entirely** — metrics-server only does CPU/memory. For `Pods`/`Object` metrics you deploy an adapter serving `custom.metrics.k8s.io` (the Prometheus Adapter is the common one, pointing at your Prometheus/Mimir); for `External` you serve `external.metrics.k8s.io` (Prometheus Adapter again, or a cloud-specific adapter, or KEDA which bundles all of this). At SAP your LGTM stack is exactly what a Prometheus Adapter would query to drive a request-rate or queue-lag HPA.

---

## Scaling behavior: the `behavior` block kills flapping

Raw proportional scaling would thrash — scale up on a spike, scale down the instant it passes, scale up again. The `behavior` block (v2) governs *how fast* and *how eagerly* the HPA moves in each direction, and its asymmetric defaults encode hard-won wisdom: **scale up fast, scale down slow.**

```yaml
spec:
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0      # react to spikes immediately
      policies:
        - type: Percent
          value: 100                     # may double the pods...
          periodSeconds: 15
        - type: Pods
          value: 4                       # ...or add 4 pods...
          periodSeconds: 15
      selectPolicy: Max                  # ...whichever is MORE (aggressive up)
    scaleDown:
      stabilizationWindowSeconds: 300    # wait 5 min of sustained low load before shrinking
      policies:
        - type: Percent
          value: 50                      # at most halve per minute
          periodSeconds: 60
      selectPolicy: Max
```

The defaults when you omit `behavior` entirely:

| Direction | Stabilization window | Rate policy | Rationale |
|-----------|---------------------|-------------|-----------|
| **scaleUp** | `0s` (immediate) | `max(4 pods, 100%)` per 15s | Under-provisioning hurts users *now*; react instantly |
| **scaleDown** | `300s` (5 min) | `100%` per 15s, but gated by the window | Over-provisioning only costs money; shrink cautiously to avoid thrash |

The **stabilization window** is the anti-flap mechanism that matters most. On scale-down, the HPA looks at *all* the desired-replica computations over the trailing window and picks the **highest** one — so a brief dip in load won't shrink you; load has to stay low for the whole window. That's why a correctly-configured HPA scales out in seconds but takes minutes to scale back in. `selectPolicy: Disabled` on `scaleDown` turns automatic scale-down off entirely (useful when you only ever want manual or scheduled shrink).

---

## VPA: right-sizing each pod

The **Vertical Pod Autoscaler** answers a different question: not "how many pods?" but "is each pod asking for the right amount?" It observes historical CPU/memory usage and recommends (or applies) better `requests`/`limits`. It has three components — a **Recommender** (watches usage, emits recommendations), an **Updater** (evicts pods that are badly sized), and an **Admission Controller** (rewrites requests on pod creation).

The critical knob is `updateMode`:

| `updateMode` | Behavior |
|--------------|----------|
| `Off` | Recommend only — writes recommendations to the VPA object, changes nothing. The safe, universally-useful mode: use it as a *sizing report*. |
| `Initial` | Sets requests only at pod creation; never disrupts a running pod. |
| `Recreate` | **Evicts** running pods to apply new requests (disruptive). |
| `Auto` | Currently same as `Recreate`; will use in-place resize as that matures. |

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: web
  namespace: dojo-scale
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web
  updatePolicy:
    updateMode: "Off"        # recommend-only; read it with `kubectl describe vpa web`
```

Two things that separate people who've run VPA from people who've read about it:

- **VPA in `Recreate`/`Auto` evicts pods — through the Eviction API — so it respects your PDB** (everything from Module 04 applies). A too-strict PDB will stall VPA updates exactly like it stalls a drain.
- **Never point an HPA and a VPA at the *same resource metric*.** If both manage CPU, they fight: the HPA scales replicas on CPU% while the VPA keeps changing the CPU request (the HPA's denominator), and the system oscillates. The legal combination is VPA on CPU/memory **+** HPA on a custom/external metric (RPS, queue depth), or VPA in `Off` mode purely for sizing advice while the HPA owns CPU. The newer **in-place pod resize** (`resizePolicy`, beta in recent releases) is what will eventually let VPA adjust requests without the eviction churn.

---

## Cluster Autoscaler & Karpenter: the node axis

The HPA and VPA both operate *within* the nodes you have. When they ask for more than fits, pods go `Pending` with `FailedScheduling: Insufficient cpu/memory`. The **Cluster Autoscaler (CA)** closes that loop by talking to your cloud provider's node groups:

```
 HPA wants +3 pods ──▶ scheduler: no room ──▶ pods Pending (Insufficient cpu)
                                                     │
                                                     ▼
                              Cluster Autoscaler sees unschedulable pods
                                                     │
                              ┌──────────────────────┴───────────────────────┐
                              ▼                                               ▼
                   scale UP: add a node to the group               scale DOWN (later):
                   that would let the pods fit                     a node is <50% utilized for
                              │                                    scale-down-unneeded-time (~10m)
                              ▼                                     → CORDON + DRAIN it
                   pods schedule onto the new node                 (respects PDBs! — Module 04)
```

Key behaviors to internalize:

- **Scale-up trigger is unschedulable pods**, not high utilization. CA adds a node only when something can't be placed — so the HPA (which creates the pods) and the CA (which creates room) are partners.
- **Scale-down is utilization-based and cautious**: a node under a threshold (default ~50%) for `scale-down-unneeded-time` (default 10 min) is a candidate, *if* everything on it can be rescheduled elsewhere. CA then **drains it through the Eviction API — honoring your PDBs.** A pod with a restrictive PDB, local storage, or no controller can pin a node open and block scale-down; the annotation `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` does this deliberately.
- **Karpenter** is the modern, groupless alternative (AWS-origin, now broader): instead of scaling fixed node groups, it provisions *right-sized* nodes just-in-time for the exact pending pods, and consolidates aggressively. Same control loop (pending pods → nodes), far less node-group bookkeeping.

On **kind there are no cloud node groups**, so the Cluster Autoscaler is conceptual in this dojo — you add worker nodes by editing the kind cluster config and recreating, not by an autoscaler. But the HPA→Pending→(would-add-node) chain is fully observable: push an HPA past what your kind workers can fit and you'll watch pods wedge in `Pending`, which is exactly the signal a CA would act on.

---

## Scale-to-zero — and why plain HPA can't

A frequent ask: "scale to 0 when idle, 1 when a request/event arrives." A vanilla `Resource`-metric HPA **cannot** do this — `minReplicas: 0` requires the `HPAScaleToZero` feature gate **and** an `Object`/`External` metric (never a Resource metric, because with zero pods there's no CPU to measure — the chicken-and-egg problem). In practice almost everyone uses **KEDA** for this:

```
 0 pods, idle
     │  KEDA watches an event source (Kafka lag, queue depth, cron, HTTP)
     ▼
 event arrives → KEDA scales 0 → 1 (it owns the 0↔1 transition)
     │
     ▼
 KEDA then creates/drives a standard HPA for the 1 → N range (External metric)
     │
     ▼
 source drains → back to 1 → 0 after a cooldown
```

KEDA is a metrics adapter + operator: it handles the special 0↔1 jump itself and generates an ordinary `autoscaling/v2` HPA (with an `External` metric) for everything above 1. For a request-driven service with no queue, the HTTP add-on (or Knative) fills the same role.

---

## Debugging autoscaling

The failure modes cluster into four buckets: **no metrics** (HPA can't see anything), **wrong metrics** (sees the wrong number), **thrash** (scales too eagerly), and **won't-shrink/won't-grow** (bounds or behavior). Diagnose with `describe hpa` first — its `Conditions` and events name the exact problem.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| HPA TARGETS shows `<unknown>/60%` | metrics-server not installed/Ready, **or** container has no CPU request (no denominator) | Install metrics-server; confirm `resources.requests.cpu` is set on the container |
| `kubectl top` errors: `Metrics API not available` | metrics-server missing or its APIService is `False` | `bash labs/bootstrap/install-metrics-server.sh`; check `kubectl get apiservice v1beta1.metrics.k8s.io` |
| metrics-server pod `Running` but `0/1 READY`, logs show x509 cert errors | kind kubelet serving cert is self-signed; metrics-server rejects it | Ensure `--kubelet-insecure-tls` is on the deployment (the dojo script adds it) |
| HPA `describe` shows `FailedGetResourceMetric` / `unable to fetch metrics` | metrics pipeline not ready yet, or RBAC for the metrics API | Wait ~30s for a scrape window; check metrics-server logs and its ClusterRole |
| Custom/external metric HPA stuck `<unknown>` | No custom/external metrics adapter deployed (metrics-server doesn't serve those) | Deploy Prometheus Adapter / KEDA serving `custom.metrics.k8s.io` or `external.metrics.k8s.io` |
| Replica count oscillates every cycle (flapping) | No scale-down stabilization, target too close to idle usage, or VPA fighting the HPA on the same metric | Set `behavior.scaleDown.stabilizationWindowSeconds: 300`; widen the target; stop VPA+HPA sharing a metric |
| Scales up but never comes back down | `behavior.scaleDown.selectPolicy: Disabled`, a stuck-high custom metric, or load genuinely sustained | Check the `behavior` block and the actual metric value over the window |
| HPA pinned at `maxReplicas`, `ScalingLimited: True` | Real demand exceeds `maxReplicas`, or a metric is returning a bogus huge value | Raise `maxReplicas` *after* confirming the metric is real; check each metric in isolation |
| `minReplicas: 0` rejected or never scales to 0 | Resource metric can't scale to zero; needs feature gate + external metric | Use KEDA (or an External-metric HPA with `HPAScaleToZero`) |

### Diagnose each — the exact commands

**`<unknown>` target — is it metrics-server or a missing request?** Check both halves:

```bash
kubectl top pods -n dojo-scale                      # errors here → metrics-server problem, stop and fix that first
kubectl -n dojo-scale get deploy web \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}{"\n"}'
# empty output → no CPU request → Utilization has no denominator → always <unknown>
```

**Read the HPA's own diagnosis.** `describe` surfaces the `AbleToScale`, `ScalingActive`, and `ScalingLimited` conditions plus the controller's events — this is the single most useful command:

```bash
kubectl -n dojo-scale describe hpa web | sed -n '/Conditions:/,/Events:/p'
kubectl -n dojo-scale describe hpa web | sed -n '/Events:/,$p'
# ScalingActive=False + FailedGetResourceMetric  → metrics not flowing
# ScalingLimited=True                            → clamped at min/max, not a bug per se
```

**metrics-server NotReady on kind — confirm the cert is the cause:**

```bash
kubectl -n kube-system get pods -l k8s-app=metrics-server
kubectl -n kube-system logs deploy/metrics-server | grep -i -E 'x509|certificate|tls' | tail
# "x509: cannot validate certificate ... because it doesn't contain any IP SANs"
#   → the --kubelet-insecure-tls flag is missing. Confirm it's present:
kubectl -n kube-system get deploy metrics-server \
  -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}'
kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}{"\n"}'
```

**Flapping — watch it happen, then look at the behavior block:**

```bash
kubectl -n dojo-scale get hpa web -w          # watch REPLICAS bounce tick-to-tick
kubectl -n dojo-scale get hpa web -o jsonpath='{.spec.behavior.scaleDown.stabilizationWindowSeconds}{"\n"}'
# empty or 0 on scaleDown is a flap waiting to happen under spiky load.
```

**Confirm no HPA/VPA metric collision** (the subtle thrash cause):

```bash
kubectl -n dojo-scale get hpa web -o jsonpath='{range .spec.metrics[*]}{.resource.name}{"\n"}{end}'
kubectl -n dojo-scale get vpa  web -o jsonpath='{range .spec.resourcePolicy.containerPolicies[*]}{.controlledResources}{"\n"}{end}' 2>/dev/null
# if both list "cpu", they are fighting — split them onto different signals.
```

> **War story.** We put an HPA on a log-enrichment service in the LGTM pipeline keyed to CPU at 70%, and for a week it behaved. Then a product launch doubled ingest and the replica count started strobing — 4 pods, 9 pods, 4, 9 — every 15 seconds, each flap triggering a fresh scheduling storm and a dip in throughput right when we needed it steady. The CPU graph was a sawtooth: scale up, load-per-pod drops below target, scale *all the way* down, load-per-pod spikes, scale up again. The default scale-down had **no stabilization window** on that chart's old API version, so the controller shrank on the very first low reading instead of waiting to be sure. Two lines fixed it: `scaleDown.stabilizationWindowSeconds: 300` so a momentary dip couldn't shrink us, and a `scaleUp` cap of `max(4 pods, 100%)/15s` so recovery was brisk but not violent. The replica count went from a sawtooth to a staircase. The principle I carried out of it: **scale up on the fear of under-provisioning, scale down on the proof of sustained calm** — asymmetric by design, never symmetric.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Name the three autoscaling axes, the controller that owns each, and the one input (requests) they all depend on.
2. Write the HPA desired-replicas formula and use it to compute the new count for 3 pods at 90% CPU against a 50% target.
3. Explain the HPA tolerance deadband and why `averageUtilization` reports `<unknown>` when the container has no CPU request.
4. List the HPA v2 metric types (Resource, ContainerResource, Pods, Object, External) and say which need an adapter beyond metrics-server — and what "multiple metrics take the max" means.
5. Describe what metrics-server serves, why kind needs `--kubelet-insecure-tls`, and the one command that confirms its APIService is Available.
6. Explain the asymmetric scale-up/scale-down defaults and what the scale-down stabilization window actually computes (the max desired over the window).
7. Give the VPA's three components and four `updateMode` values, and state the one rule about never sharing a metric with an HPA.
8. Trace the HPA → Pending → Cluster Autoscaler chain, and explain why CA scale-down drains nodes through the Eviction API (and thus honors PDBs).
9. Explain why a plain Resource-metric HPA can't scale to zero, and what KEDA does to make 0↔1 work.

➡ Next up: the course's autoscaling challenge — you'll take the spec knowledge here and prove a correct, flap-resistant HPA against a live verifier, then watch it scale under real generated load once metrics-server is feeding it.
