# Drain Without Downtime

The on-call ticket is routine and terrifying in equal measure: *"Kernel CVE — patch every worker node this week."* Patching a node means taking it out of rotation, and the last engineer who "just rebooted a node" took the checkout service down for four minutes because every replica happened to live there.

You're going to do it the right way: **cordon** the node so nothing new schedules onto it, then **drain** it so the pods already there are evicted *gracefully* and rescheduled elsewhere — and the drain will respect a `PodDisruptionBudget` so the app never dips below a safe number of ready pods.

## The two verbs, precisely

| Verb | What it does | What it does *not* do |
|------|--------------|-----------------------|
| `kubectl cordon <node>` | Sets `.spec.unschedulable=true`. The scheduler stops placing **new** pods here. | Does **not** touch pods already running on the node. |
| `kubectl drain <node>` | Cordons (if needed), then **evicts** every evictable pod via the Eviction API, which honors PDBs. | Blocks on pods it can't evict safely (bare pods, DaemonSets, local storage) unless you tell it otherwise. |

Drain is picky on purpose. You almost always need these flags:

| Flag | Why |
|------|-----|
| `--ignore-daemonsets` | DaemonSet pods (CNI, kube-proxy, log shippers) are *supposed* to run on every node and will be recreated instantly; drain refuses to start until you acknowledge them. |
| `--delete-emptydir-data` | A pod using an `emptyDir` volume holds data that dies with it; drain won't evict it unless you confirm that loss is acceptable. |
| `--grace-period` / `--timeout` | Bound how long you wait for graceful termination before giving up. |

## How the PDB changes the drain

The scenario ships a Deployment `web` (3 replicas, label `app=maint`) spread across your worker nodes, plus a **PodDisruptionBudget** with `minAvailable: 2`. The budget is what turns a reckless reboot into a safe one:

```
drain wants to evict a pod on dojo-worker
        │
        ▼
Eviction API asks: "after this eviction, are >= 2 pods still Available?"
        │
   ┌────┴────┐
 yes│         │no
   ▼          ▼
 evict     BLOCK — drain retries until a
 the pod   replacement pod becomes Ready
           elsewhere, then proceeds
```

So the drain doesn't fail on a healthy app — it **paces itself**, evicting one pod, waiting for the Deployment to bring up a replacement on the other worker and pass its readiness probe, then evicting the next. That pacing is the entire reason your checkout service stays up during a fleet-wide patch.

## Mission

In namespace `dojo-maint`:

1. Pick one **worker** node that is currently running `web` pods.
2. **Cordon** it, then **drain** it (respecting the PDB, ignoring DaemonSets, and allowing emptyDir deletion so the drain can complete).
3. Leave the app healthy on the remaining node(s).

## Target state (what the verifier checks)

The verifier accepts your work only when **all** of these hold:

1. **At least one worker node is `SchedulingDisabled`** — i.e. cordoned (`.spec.unschedulable=true`). The control-plane node doesn't count.
2. **Deployment `web` has `readyReplicas >= 2`** — the app survived the drain.
3. **No `Running` `app=maint` pod remains on the cordoned node** — the drain actually evicted them.

> You do **not** need to uncordon afterward. In the real world you would (`kubectl uncordon <node>`) once the patch is done — but the verifier is checking the *mid-maintenance* steady state, which is the risky window.

## Why this matters

A `kubectl delete node` or a hard reboot is a **non-graceful** disruption: pods vanish, connections are cut mid-flight, and nothing honors your PDB. `drain` routes the same outcome through the **Eviction API**, which is the only path that respects disruption budgets and gives pods their `terminationGracePeriodSeconds` to finish in-flight requests. Knowing the difference is what separates "I rebooted the node" from "I performed node maintenance."

When you believe the cluster is in the target state, run the verifier. It inspects live cluster state and prints the flag only if every check passes.
