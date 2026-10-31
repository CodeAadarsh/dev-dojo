# Who Gets Evicted First

3 a.m. page: a batch reconciliation job scaled up overnight, packed the nodes, and the kube-scheduler started making decisions you never told it to make. When memory got tight, the kubelet's eviction manager reaped pods to save the node — and it reaped `payments`. The batch job, meanwhile, kept running. Your revenue path went down so a nightly CSV export could finish.

The fix is not "add more nodes." It is telling Kubernetes, explicitly and in writing, **which workloads matter more than others** — so that when something has to give, it is never the payments path.

That lever is **Pod priority**. This challenge wires it onto the `payments` Deployment in namespace `dojo-priority`.

## Priority vs. preemption vs. eviction — three different things

People blur these together. They fire at different times, driven by different components:

| Mechanism | Who runs it | When it fires | What it uses |
|-----------|-------------|---------------|--------------|
| **Preemption** | kube-scheduler | A pending pod cannot be scheduled because the node is full | Pod **priority** — evicts lower-priority pods to make room for a higher-priority pending one |
| **Node-pressure eviction** | kubelet (per node) | A node is under real resource pressure (memory/disk) | QoS class first, then priority as a tiebreak within a QoS band |
| **API-initiated eviction** | you / autoscaler / drain | Voluntary — `kubectl drain`, cluster upgrade | Respects PodDisruptionBudgets |

This challenge is about the first one: **priority drives scheduler preemption**, and priority also acts as a tiebreaker the kubelet consults when it has to choose victims under node pressure. A higher-priority pod is scheduled sooner and killed later. That is the whole game.

## How priority actually works

A `PriorityClass` is a **cluster-scoped** object that maps a name to an integer `value`. A pod references it by name via `spec.priorityClassName`; the admission controller stamps the resolved integer onto `spec.priority` at creation time. Higher integer = more important.

```
 PriorityClass (cluster-scoped)          Pod (namespaced)
 ┌───────────────────────────┐           ┌───────────────────────────┐
 │ name:  dojo-critical       │◄──────────│ spec.priorityClassName:    │
 │ value: 1000000             │  by name  │       dojo-critical        │
 │ preemptionPolicy:          │           │ spec.priority: 1000000 ◄───┼── stamped
 │   PreemptLowerPriority     │           │   (set by admission)       │   at admit
 └───────────────────────────┘           └───────────────────────────┘
```

The two reserved, pre-installed classes sit at the top and are **off-limits for app workloads**:

| Class | Value | Purpose |
|-------|------:|---------|
| `system-node-critical` | 2000001000 | kubelet, CNI, the stuff a node cannot run without |
| `system-cluster-critical` | 2000000000 | core control-plane add-ons (CoreDNS, etc.) |

Never park your app at those values — you will starve the plane that keeps the node alive. App priorities live far below, in the thousands-to-millions range you define yourself.

## Mission

The setup script deployed `payments` into `dojo-priority` with **no priority at all** (so its effective priority is 0 — the same as every noisy-neighbor batch pod). Promote it:

1. **Create a `PriorityClass`** of your own — cluster-scoped, with a genuinely high `value` (**≥ 100000**; `1000000` is the suggested, readable choice). Do **not** reuse a `system-*` class.
2. **Bind the `payments` Deployment to it** by setting `spec.template.spec.priorityClassName` to your class, so every pod it rolls out inherits the priority.
3. Keep the Deployment **running** — at least one pod must come back `Ready` under the new template.

## What the verifier checks

`verify.sh` inspects live cluster state and accepts your work only when **all** of these hold:

1. The `payments` Deployment's pod template sets a non-empty `spec.template.spec.priorityClassName`.
2. That name resolves to a **real, existing** `PriorityClass` (cluster-scoped).
3. That class's `value` is **≥ 100000** and its name does **not** start with `system-` (your own high-value class, not a borrowed system one).
4. The Deployment has **≥ 1 `readyReplicas`** — the new template actually schedules and runs.

Get all four green and the verifier prints your flag.

## Why this matters

Priority is cheap insurance that costs nothing until the one night you need it. Without it, the scheduler treats your revenue path and a throwaway cron the same — priority 0 vs. priority 0, decided by luck. With it, a pending high-priority `payments` pod will **preempt** lower-priority tenants to get scheduled, and under node pressure the kubelet reaches for the low-priority pods first. The dangerous failure mode is the inverse: set priority too *high* (near the `system-*` band) across many app pods and you can preempt infrastructure or create a priority arms race where everything is "critical" and therefore nothing is. Priority is a ranking, and a ranking only works if most things are *not* at the top.
