# GitOps or It Didn't Happen

Your team just adopted the rule every mature platform eventually lands on: **if a change isn't in Git and reconciled by the controller, it didn't happen.** No more `kubectl apply` from laptops, no more "I fixed it in prod, I'll backport the YAML later." The cluster's desired state lives in a repo; a controller makes reality match it, continuously.

You run this at work already — the muscle here is proving you can *declare* an Argo CD `Application` correctly from scratch, including the part most people fumble: `syncPolicy.automated` with `prune` and `selfHeal`, and getting the destination/namespace wiring right so the app lands where you intended.

## Prerequisite

Argo CD must be installed in the cluster. If you haven't already:

```bash
bash labs/bootstrap/install-argocd.sh
```

That installs Argo CD into the `argocd` namespace and prints the UI URL + initial admin password. The verifier and this challenge assume Argo CD's CRDs (`applications.argoproj.io`) and controllers are running there.

## The setup

Running `setup.sh` does two small things and deliberately **no more**:

- ensures the target namespace `dojo-gitops` exists,
- checks that the `argocd` namespace is present (warns loudly if it isn't).

It does **not** create the Application. That's your mission — the whole point is that you author the declarative source of truth.

## Mission

Create an Argo CD `Application` (the `Application` object itself lives in the `argocd` namespace) that deploys the public example app:

| Field | Value |
|-------|-------|
| `spec.source.repoURL` | `https://github.com/argoproj/argocd-example-apps` |
| `spec.source.path` | `guestbook` |
| `spec.source.targetRevision` | `HEAD` |
| `spec.destination.server` | `https://kubernetes.default.svc` (the in-cluster API) |
| `spec.destination.namespace` | `dojo-gitops` |
| `spec.syncPolicy.automated` | `prune: true`, `selfHeal: true` |

Then make it sync, so the guestbook workload actually lands in `dojo-gitops` and the Application reports healthy.

## Target state — what the verifier checks

The verifier walks every `Application` in the `argocd` namespace and accepts your work only when **one** of them satisfies **all** of:

1. **`spec.destination.namespace == dojo-gitops`** — it's targeting the right place.
2. **`status.sync.status == Synced`** — live cluster state matches the manifests in Git.
3. **`status.health.status == Healthy`** — the deployed resources are actually up, not just applied.

> **Why `Synced` *and* `Healthy` are different questions.** `Synced` means "what's in the cluster equals what's in Git." `Healthy` means "the running resources are actually working." You can be `Synced` but `Degraded` (the manifests applied, but the pod is crash-looping), and you can be briefly `OutOfSync` but `Healthy` (someone drifted a live object that still happens to run). Expert GitOps operators watch both axes — a green "Synced" badge over a dead service is the classic false comfort.

When all three hold, the verifier prints your flag.
