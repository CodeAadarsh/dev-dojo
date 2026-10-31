# Guarantee It

The `cache` service keeps getting blamed for p99 latency spikes that correlate with "the node was busy." The owning team swears the code didn't change. They're right — the code didn't. The problem is that `cache` ships as a **Burstable** pod with a fuzzy resource spec, so under node pressure the Linux CFS scheduler throttles its CPU and the kernel OOM killer eyes it before it eyes the batch jobs next to it. The pod is a second-class citizen on its own node and nobody declared it so on purpose.

You're going to make the kernel treat it like it matters: push it into the **Guaranteed** QoS class.

## The three QoS classes — and what they actually buy you

Kubernetes assigns each pod a QoS class **derived from its resource spec** — you don't set it directly, you *earn* it. The class is stamped on `status.qosClass` and drives two kernel-level behaviors: **OOM-kill order** and **CPU throttling**.

| QoS class | How you get it | `oom_score_adj` | Behavior under pressure |
|-----------|----------------|-----------------|--------------------------|
| **Guaranteed** | *Every* container sets `requests == limits` for **both** cpu and memory | -997 | Killed **last**; CPU not throttled below its request; eligible for static CPU pinning |
| **Burstable** | At least one request set, but not the strict equality above | 2..999 (scales with usage) | Killed **in the middle**; can burst above requests but gets throttled/reaped when the node is tight |
| **BestEffort** | No requests or limits anywhere | 1000 | Killed **first**; pure scavenger |

The OOM killer picks victims by the kernel's `oom_score`, and the kubelet biases that score via `oom_score_adj`. Guaranteed's `-997` means: among your workloads, this pod is the kernel's *last* choice when memory runs out. That is the guarantee — not "more resources," but **"last to be hurt."**

```
 node memory pressure rising ─────────────────────────────────►
   BestEffort pods        Burstable pods          Guaranteed pods
   (killed first)   ──►   (killed next)     ──►    (killed last)
   oom_score_adj 1000     oom_score_adj 2..999     oom_score_adj -997
```

## The rule that trips everyone up

**Guaranteed requires `requests == limits` for cpu AND memory on EVERY container in the pod.** The subtle parts:

- Set **only limits** (no requests)? Kubernetes copies limits into requests for you, so `requests == limits` — that *also* yields Guaranteed. (Setting only requests does **not**.)
- Miss **one** resource — e.g. memory matched but cpu only has a request — and the whole pod drops to **Burstable**. There is no "partial credit."
- One sidecar without matching requests/limits taints the **entire pod** to Burstable, even if your main container is perfect. QoS is a pod-level verdict computed from all containers.

## Mission

The setup script deployed `cache` into `dojo-qos` as **Burstable** — it has a cpu request and a memory request, but no limits, so it is not Guaranteed. Fix the pod template so every pod lands in **Guaranteed**:

1. Set **both** `requests` and `limits` for **cpu** and **memory** on the `cache` container.
2. Make them **equal**: `requests.cpu == limits.cpu` and `requests.memory == limits.memory`.
3. Roll it out so at least one new pod comes back **Ready** in the Guaranteed class.

## What the verifier checks

`verify.sh` reads **live pod status** (not your YAML — the real computed verdict) and accepts your work only when:

1. The `cache` Deployment reports **≥ 1 `readyReplicas`**.
2. There is a `cache` pod that is **`Ready`** and whose **`status.qosClass == Guaranteed`**.

Both green and the verifier prints your flag.

## Why this matters

QoS is the one reliability knob you set by *doing nothing special* — just making your numbers match. It costs you a little headroom (you give up the right to burst above your limit) in exchange for predictability: no surprise CPU throttling, and you're the kernel's last OOM target. For a cache, a sidecar proxy, or anything on the latency-critical path, that trade is almost always correct. The anti-pattern is making *everything* Guaranteed — then you've just set `requests = limits = peak` cluster-wide, destroyed your ability to overcommit, and your bin-packing efficiency falls off a cliff. Guaranteed is a scalpel for the pods that genuinely cannot tolerate throttling, not a blanket.
