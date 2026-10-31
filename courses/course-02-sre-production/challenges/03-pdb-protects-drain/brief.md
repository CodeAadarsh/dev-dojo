# Budget for Disruption

It's a Tuesday-night cluster upgrade. The platform team runs `kubectl drain` across the node pool, one node at a time, to cordon and evict pods so each node can be recycled onto the new Kubernetes version. Routine. Except your `api` service has all three of its replicas scheduled onto two nodes, and when the first of those nodes drains, **two of three pods get evicted simultaneously** — and the third is on the node that's next in line. For ninety seconds the service is down to one pod (or zero), during a change nobody thought was risky.

Nothing was *broken*. The drain did exactly what you told it to: evict pods so the node can go. The missing piece is a signal that says *"you may disrupt this app, but not below this floor."* That signal is a **PodDisruptionBudget (PDB)**.

## Voluntary vs. involuntary — the distinction a PDB is built on

A PDB **only** governs *voluntary* disruptions — the ones initiated through the Eviction API. It does **nothing** for involuntary ones.

| Disruption | Type | Does a PDB protect it? |
|------------|------|------------------------|
| `kubectl drain` (node maintenance, upgrade) | Voluntary | ✅ Yes — eviction is blocked below the budget |
| Cluster autoscaler scaling down a node | Voluntary | ✅ Yes |
| Node reboot via the Eviction API | Voluntary | ✅ Yes |
| A node's kernel panics / hardware dies | Involuntary | ❌ No — the pods are just gone |
| An OOM kill, a `kubectl delete pod` | Involuntary | ❌ No |
| The pod's own `maxUnavailable` during a rollout | Neither — that's the Deployment | ❌ No (different mechanism) |

The mental model: a PDB is a **contract with the eviction API**. When something calls `Evict` on one of your pods, the API server checks every PDB whose selector matches that pod and asks *"if I remove this pod, will this app still meet its budget?"* If not, the eviction is **rejected with a 429**, and a well-behaved drain (`kubectl drain` is one) backs off and retries — pod by pod, as replacements come up — instead of nuking them all at once.

```
   WITHOUT a PDB                         WITH minAvailable: 2 (3 replicas)
   kubectl drain node-a                  kubectl drain node-a
     evict api-1  ──▶ gone                 evict api-1  ──▶ 429? no, 2 still up ──▶ gone
     evict api-2  ──▶ gone   DOWN TO 1     evict api-2  ──▶ 429! would leave 1 ──▶ BLOCKED, retry
     (api-3 next node, also drains)        (drain waits for a replacement to go Ready,
      ...brief outage...                     then proceeds) — floor of 2 held the whole time
```

## Mission

The setup script plants a Deployment `api` with **3 replicas** in namespace `dojo-pdb` and **no PodDisruptionBudget**. Add one that holds a floor of availability during voluntary disruptions.

## Target state

The verifier accepts your work only when **all** of these are true in namespace `dojo-pdb`:

1. **A `PodDisruptionBudget` exists** in `dojo-pdb` with **`minAvailable: 2`** (an integer `2`, not a percentage).
2. Its **`selector` actually matches the `api` pods** — the verifier confirms the PDB is counting real pods, not pointing at a label nobody has. A PDB with a typo'd selector silently protects *nothing*.
3. **The Deployment has `readyReplicas` ≥ 2** — the app is healthy enough that the budget is meaningful (a budget over a dead Deployment is theatre).

## Rules of engagement

- Work in namespace `dojo-pdb` (the setup script creates it and plants `api`).
- The `api` pods carry the label `app: api`. Your PDB's `selector.matchLabels` must match that.
- Use `kubectl apply` of a `policy/v1` PodDisruptionBudget manifest, or `kubectl create pdb`. Either is fine — the verifier only inspects final state.
- Use **`minAvailable: 2`** specifically. (`maxUnavailable: 1` is equivalent for 3 replicas, but this challenge standardizes on `minAvailable` so the verifier can check one field unambiguously.)

## `minAvailable` vs `maxUnavailable` — pick the one that stays correct as you scale

A PDB takes **exactly one** of these:

- **`minAvailable: 2`** — "always keep at least 2 pods up." The floor is absolute; if you scale the Deployment to 10, you still only guarantee 2, so the *budget for disruption* grows (you can lose 8 at once).
- **`maxUnavailable: 1`** — "never take more than 1 down at a time." The ceiling on disruption is absolute; scale to 10 and you still only ever lose 1 at a time.

For a fixed small replica count they can be equivalent (`minAvailable: 2` ≡ `maxUnavailable: 1` at 3 replicas). The rule of thumb: use **`maxUnavailable`** when you care about *disruption rate* regardless of size (most HPA-backed services), and **`minAvailable`** when you have a hard floor below which the app is useless (quorum systems — a 3-node etcd/ZooKeeper needs `minAvailable: 2` to keep quorum, full stop).

When the PDB is in place, run the verifier (section 3 above). It inspects your live cluster and prints the flag only if every check passes.
