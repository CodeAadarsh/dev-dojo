# Resource Starvation

Post-incident review. A node went red with memory pressure at 02:14, the kubelet started evicting, and the first thing it killed was the `api` pod in `dojo-resources` — not the batch job hammering the box, the customer-facing API. The reason is in one line of the manifest: the container has **no resource requests and no limits**. Kubernetes classed it `BestEffort`, which means *"kill me first."*

This is the SRE boundary between competent and expert: you don't just make a pod run, you decide **how it behaves when the node runs out**. That behaviour is the pod's **QoS class**, and it is derived entirely from the requests and limits you set.

## QoS classes — the only three

Kubernetes assigns each pod one of three classes from its containers' requests/limits. You never set the class directly; you *earn* it:

| QoS class  | How you get it                                                                 | Behaviour under node pressure |
|------------|--------------------------------------------------------------------------------|-------------------------------|
| `Guaranteed` | **Every** container has requests **and** limits set, and for each resource `requests == limits` | Evicted **last**. Lowest OOM score. |
| `Burstable`  | At least one container has a request or limit, but not the Guaranteed pattern | Evicted **after** BestEffort, before Guaranteed. |
| `BestEffort` | **No** container sets any request or limit                                     | Evicted **first**. Highest OOM score. The `api` pod above. |

```
node memory pressure  ──────────────────────────────────▶ time
  ┌───────────────┐   ┌──────────────┐   ┌───────────────┐
  │  BestEffort   │   │  Burstable   │   │  Guaranteed   │
  │  killed 1st   │─▶ │ killed 2nd   │─▶ │  killed last  │
  │ oom_score_adj │   │ (over its    │   │ oom_score_adj │
  │   = 1000      │   │  request)    │   │   = -997      │
  └───────────────┘   └──────────────┘   └───────────────┘
        api pod            most apps          critical / infra
```

Two distinct killers are in play, and they rank pods the same way:

- **kubelet eviction** (proactive): when a node crosses a soft/hard memory threshold, the kubelet ranks pods by QoS and by how far each is *over its request*, and evicts to reclaim. BestEffort and pods most over their request go first.
- **kernel OOM killer** (reactive): if memory is exhausted faster than the kubelet reacts, the Linux OOM killer fires. The kubelet writes each container's `oom_score_adj` from its QoS — BestEffort gets `+1000` (prime target), Guaranteed gets `-997` (nearly immune). So even the raw kernel kill order follows your requests and limits.

**requests** drive *scheduling and eviction ranking* (the scheduler packs pods by request; a pod over its memory request is eviction fodder). **limits** drive *enforcement* (CPU is throttled at its limit; memory over its limit is an instant OOM-kill of that container). Set both and you control both halves.

## Mission

The setup script deployed a workload in namespace `dojo-resources` with a container that has **no requests and no limits** (BestEffort — the worst case). Bring it to a safe state **and** make the whole namespace safe by default:

1. **Add CPU and memory `requests`** to the container (`resources.requests.cpu` and `resources.requests.memory`).
2. **Add CPU and memory `limits`** to the container (`resources.limits.cpu` and `resources.limits.memory`).
3. **Create a `LimitRange`** in `dojo-resources` that sets a **default request and default limit** for containers, so any future pod that forgets — like the one that caused the incident — is auto-upgraded out of BestEffort at admission time.

## Target state

The verifier accepts your work only when **all** of these are true in namespace `dojo-resources`:

1. The workload's **container[0] has `resources.requests`** set (non-empty).
2. The workload's **container[0] has `resources.limits`** set (non-empty).
3. **A `LimitRange` exists** in `dojo-resources`.

## Rules of engagement

- Work in namespace `dojo-resources` (the setup script creates it and the workload).
- The workload is named `api`, image `nginx:1.27-alpine`, serving on port 80.
- You may `kubectl edit`, `kubectl set resources`, or `kubectl apply` edited YAML — the verifier inspects final state only.

> **Order matters if you rely on the LimitRange to supply defaults.** A `LimitRange` only stamps defaults onto pods created **after** it exists; it does not retroactively mutate the running `api` pod. So either set the container's requests/limits explicitly (satisfies checks 1–2 directly), or apply the LimitRange first and then force a rollout so new pods inherit the defaults. The cleanest answer does both: explicit values on `api`, plus a LimitRange as the namespace safety net.

When the cluster is in the target state, run the verifier. It inspects the live Deployment and the namespace's LimitRange and prints the flag only if every check passes.
