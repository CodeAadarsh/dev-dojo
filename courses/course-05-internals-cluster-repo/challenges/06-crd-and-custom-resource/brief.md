# Teach the API a New Word

Every operator you run at work — cert-manager, Prometheus Operator, Argo Rollouts — started with the same primitive: somebody taught the API server a noun it didn't know. `kubectl get certificates`, `kubectl get prometheuses`, `kubectl get rollouts` all work because a **CustomResourceDefinition** registered that kind, and from that instant the API server serves a full REST surface for it — validated, versioned, RBAC-governed, watchable — with **no restart and no code**.

In this challenge you build that from scratch. No controller yet (that's the operator's job, covered conceptually below); just the thing a controller watches: a new API kind and an instance of it.

```
   you apply a CRD                        the API server, immediately:
   ┌────────────────────────────┐        ┌──────────────────────────────────────────┐
   │ kind: CustomResourceDefn    │  ───►  │ registers /apis/dojo.local/v1/widgets      │
   │ group: dojo.local           │        │ stores Widget CRs in the SAME etcd under   │
   │ names.kind: Widget          │        │   /registry/dojo.local/widgets/...         │
   │ openAPIV3Schema (spec.size) │        │ validates every CR at admission (no webhook)│
   └────────────────────────────┘        │ sets status.conditions Established=True    │
                                          └──────────────────────────────────────────┘
   then you apply a Widget CR  ──────────►  kubectl get widgets -n dojo-crd  (a first-class noun)
```

## What a CRD actually is

A CustomResourceDefinition is itself a built-in Kubernetes object (`apiextensions.k8s.io/v1`) handled by the **apiextensions-apiserver** baked into the control plane. When you create one, that component wires up a new REST endpoint and starts persisting instances in the cluster's own etcd under `/registry/<group>/<plural>/...`. Three rules separate a CRD that works from one that silently never becomes usable:

| Rule | Why | Failure if you skip it |
|------|-----|------------------------|
| `metadata.name` **must** be `<plural>.<group>` | the apiextensions server parses the name to derive routing | CRD stuck, `NamesAccepted=False` |
| exactly **one** `versions[*]` has `storage: true` | that's the version actually persisted in etcd | apply rejected: "must have exactly one storage version" |
| the schema is **structural** (typed, no bare `x-kubernetes-preserve-unknown-fields` at root) | required for v1 CRDs, enables validation + pruning | `Established=False`, schema errors |

The signal that it's live is a condition on the CRD's own status: **`Established=True`**. Until then, `kubectl get widgets` returns `the server doesn't have a resource type "widgets"`.

## Mission

1. **Define and apply a CRD** that teaches the API the kind **`Widget`**:
   - group `dojo.local`, kind `Widget`, plural `widgets` → so `metadata.name` is `widgets.dojo.local`
   - `scope: Namespaced`
   - one served + storage version (e.g. `v1`)
   - an `openAPIV3Schema` that makes **`spec.size` required** (so a Widget without a `size` is rejected at admission — prove your schema actually validates).
2. **Create a `Widget` custom resource** in namespace **`dojo-crd`** that satisfies the schema (has a `spec.size`).

## Target state — exactly what the verifier checks

1. **The CRD `widgets.dojo.local` exists** and its status condition **`Established` is `True`** (the apiextensions server accepted the schema and is serving the endpoint).
2. **At least one `Widget` custom resource exists in namespace `dojo-crd`**.

## Rules of engagement

- Work in namespace `dojo-crd` (the setup script creates it). The CRD itself is cluster-scoped — it has no namespace — but your Widget CR lives in `dojo-crd`.
- No controller is required. A CRD with no controller is just validated, typed storage — which is exactly what you're proving here.
- Run the verifier once the CRD is `Established` and your Widget exists; it prints the flag when both checks pass.

## Why this matters — the operator pattern

A CRD alone is inert: it's schema-validated YAML sitting in etcd. It becomes an **operator** when you pair it with a **controller** running a level-triggered reconcile loop: `watch(Widget) → for each Widget, compare desired spec to the real world → make one step toward it → update .status → requeue`. The controller is what turns `spec.size: 5` into five actual pods, or a `Certificate` into a real signed cert. The CRD is the *contract* (what fields exist, what's valid); the controller is the *behavior*. You're authoring the contract here — the half that must be rock-solid before any controller can trust its input, because the schema is the one validation an operator gets *for free, synchronously, impossible to bypass.*

> If you want the full controller mechanics — reconcile idempotency, the `status` subresource, owner references, conversion webhooks between versions — see Module 05 (*Extending the API: CRDs, Aggregation & Operators*). This challenge is the foundation it builds on.
