# Anti-Affinity Spread for StatefulSets

An alert fires at 3am: *cache tier completely unavailable*. You pull up the node list and see that all three `cache` pods were on `dojo-worker` — the node that just went into kernel panic. The StatefulSet had three replicas, but they all scheduled to the same node because nobody told the scheduler not to colocate them.

This is one of the most common HA mistakes in Kubernetes. Replica count ≠ availability: if all replicas land on one node, you have a single point of failure. The fix is `podAntiAffinity`.

## Why podAntiAffinity (not just replicas)

The Kubernetes scheduler is placement-greedy: it finds a node that satisfies the pod's resource requests and places it there. Without explicit spread rules it happily packs all replicas of a StatefulSet onto one beefy node. `podAntiAffinity` adds a scheduling constraint that says *"don't place this pod on a node that already runs a pod matching these labels."* With `requiredDuringSchedulingIgnoredDuringExecution`, this is a hard rule — if no other node exists, the pod stays `Pending` rather than collocate.

`topologyKey: kubernetes.io/hostname` is the right key here: it treats each distinct hostname (node) as the unit of isolation. For zone-level spread (e.g., AWS AZs) you'd use `topology.kubernetes.io/zone`.

## Setup note

The setup script untaints the control-plane node so all three nodes in the dojo cluster are schedulable. This is intentional: with only two worker nodes and a hard anti-affinity rule, the third replica would stay `Pending` forever. In production you'd use worker-only nodes with enough capacity; in the dojo we use all three nodes.

## Target state

The verifier accepts your work when **both** are true for StatefulSet `cache` in namespace `dojo-spread`:

1. **`spec.template.spec.affinity.podAntiAffinity` is configured** — the StatefulSet has anti-affinity rules using the `app: cache` label.
2. **Pods are running on more than one distinct node** — the spread is actually in effect, not just declared.

## Rules of engagement

- Work in namespace `dojo-spread` (the setup script creates it and plants the StatefulSet).
- The StatefulSet is named `cache` — patch it in-place with `kubectl patch` or `kubectl edit`, or `kubectl apply -f` a corrected manifest.
- Use `requiredDuringSchedulingIgnoredDuringExecution` with `topologyKey: kubernetes.io/hostname` — that's the hard spread guarantee worth testing.
- After applying the anti-affinity, delete the existing pods (or let the StatefulSet controller roll them): `kubectl -n dojo-spread delete pods -l app=cache`. They will reschedule respecting the new rules.

When all 3 pods are `Running` and on at least 2 different nodes, run the verifier.
