# Pin the Pod

Capacity planning hands you a ticket: *"The `pinme` service must run **only** on our `tier=gold` node — that box has the licensed CPU feature / the NVMe-backed local volume / the reserved headroom. Right now it schedules wherever the scheduler feels like it. Make it stick to gold."*

This is the daily reality of **node targeting**: GPU pools, licensed nodes, data-locality, PCI-isolated workloads, Windows vs Linux pools. Getting it right — and knowing *why* it's right — is what separates "it happened to land there" from "it is guaranteed to land there."

## The three ways to influence placement (and why this one)

| Mechanism | Lives on | Says | Hard or soft |
|-----------|----------|------|--------------|
| `nodeSelector` | pod spec | "only nodes with these labels" | hard, but no OR / no operators |
| `nodeAffinity` (required) | pod spec | "only nodes matching this expression" | **hard** — Pending if unmet |
| `nodeAffinity` (preferred) | pod spec | "prefer these, but run anywhere if not" | soft — never Pending |
| taint + toleration | node + pod | "keep *everyone else off* this node" | hard, repels by default |

`nodeSelector` would work here but it's a dead end the moment you need `In (gold, platinum)` or an existence check — it's equality-only. **`nodeAffinity` with `requiredDuringSchedulingIgnoredDuringExecution`** is the expressive, future-proof answer, and it's what this challenge requires.

> **Attraction vs repulsion — the one sentence to remember.** Affinity is a property of the **pod** and *pulls it toward* matching nodes. A taint is a property of the **node** and *pushes every pod away* unless it tolerates the taint. They solve different halves of the problem. Pinning *this* pod to gold is affinity. Keeping *other* pods off gold would be a taint. You only need affinity here — but see the solution for why belt-and-suspenders uses both.

```
          nodeAffinity (on the pod)                 taint (on the node)
   pod ───────────── pulls toward ────────▶ [gold]   [gold] ──── repels ────▶ every pod
                                                              (unless it tolerates)
```

## Mission

The setup script:

- created namespace `dojo-sched`,
- labelled **one worker node** with `tier=gold` (find it: `kubectl get nodes -l tier=gold`),
- deployed `pinme` (3 replicas of `nginx:1.27-alpine`) with **no placement rules**, so its pods are scattered across whatever workers had room.

Your job: add a **required** `nodeAffinity` rule to the `pinme` Deployment so that it schedules **only** onto the `tier=gold` node, then roll the pods so they actually land there.

## Target state — exactly what the verifier checks

The verifier accepts your work only when **all** of these hold for Deployment `pinme` in `dojo-sched`:

1. The pod template has `spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution` with a match expression on key **`tier`** including the value **`gold`** (soft / `preferred` rules are rejected — they don't *guarantee* placement).
2. The Deployment's desired replica count of pods are **Running and Ready**.
3. **Every** `pinme` pod's `.spec.nodeName` equals the node currently labelled `tier=gold` — not "most of them," all of them.

Check 3 is the one that bites: adding the affinity to the spec is not enough if old pods created *before* your edit are still sitting on other nodes. `IgnoredDuringExecution` means Kubernetes will not evict already-running pods to honour a newly-added rule — you must trigger a rollout.

When the cluster is in the target state, run the verifier. It prints the flag only if every check passes.
