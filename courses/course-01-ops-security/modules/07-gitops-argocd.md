# GitOps with ArgoCD

> **Module 07 · Course 01** — `kubectl apply` by hand is how clusters drift. You run a one-off patch at 2am during an incident, forget to commit it, and now the live state and the repo disagree — silently, until the next deploy stomps your fix or resurrects a bug. GitOps closes that loop: Git is the single source of truth, and a controller continuously reconciles the cluster to match it. You operate ArgoCD at work; this module is about reasoning precisely about *what reconciliation actually does* and where it bites.

---

## GitOps principles — pull, not push

GitOps is four claims, and the fourth is the one that separates it from "we store YAML in Git":

1. **Declarative.** The entire desired state is declarative config (manifests, Helm, Kustomize).
2. **Versioned & immutable.** That state lives in Git — audited, reviewable, revertible. A rollback is `git revert`.
3. **Pulled automatically.** An agent *in the cluster* pulls the desired state and applies it.
4. **Continuously reconciled.** The agent constantly observes actual vs. desired and corrects drift — forever, not just at deploy time.

The pull-vs-push distinction is the crux:

```
   PUSH model (CI pipeline deploys)              PULL model (GitOps)
   ┌──────────┐   kubectl apply   ┌──────┐       ┌──────┐   watches   ┌─────────┐
   │  CI job   │ ───────────────▶ │cluster│      │ Git  │ ◀────────── │ ArgoCD  │
   └──────────┘  (creds OUTSIDE)  └──────┘       └──────┘   (in-       │ in      │
                                                      │       cluster)  │ cluster │
   CI holds cluster-admin creds.                      └──────apply─────▶│         │
   Drift is invisible between runs.                                     └─────────┘
```

Why pull wins in production:

- **No cluster credentials outside the cluster.** In the push model, your CI system holds a kubeconfig with broad rights — a juicy target. In the pull model the controller lives *inside* the cluster and reads Git; CI only needs push access to a repo.
- **Drift is detected, not just overwritten at deploy time.** Someone `kubectl edit`s a live Deployment? The controller sees the divergence and (optionally) reverts it. The push model never notices until the next pipeline run.
- **The repo is the audit log.** Who changed what, when, and why is `git log` — not a Slack thread.

---

## Install recap

The lab ships an idempotent installer; don't hand-type the manifests:

```bash
bash labs/bootstrap/install-argocd.sh
```

That creates the `argocd` namespace, applies the stable upstream manifests, waits for `argocd-server` to roll out, then prints the UI port-forward command and the initial `admin` password (read from the `argocd-initial-admin-secret`). Reach the UI at `https://localhost:8081` after:

```bash
kubectl -n argocd port-forward svc/argocd-server 8081:443
```

ArgoCD's own components (the `application-controller`, `repo-server`, `redis`, `argocd-server`, `applicationset-controller`) all live in the `argocd` namespace — and, being Kubernetes objects, could themselves be GitOps-managed (the "self-managed ArgoCD" pattern). For the dojo we install it imperatively once.

> **The `repo-server` is where most "it won't sync" pain originates.** It's the component that clones your Git repo and renders the manifests (runs `helm template`, `kustomize build`). If your Helm chart needs a plugin, a private chart dependency, or network egress the `repo-server` pod doesn't have, rendering fails there — not in the `application-controller`. When a sync is broken for no obvious reason, `kubectl -n argocd logs deploy/argocd-repo-server` is the log that tells the truth.

---

## The Application CRD — the unit of GitOps

An `Application` is ArgoCD's core object: it marries a **source** (where the manifests are) to a **destination** (which cluster/namespace they go to), under a **project** (a policy boundary).

```
Application
  ├── source        WHERE the desired state lives
  │     repoURL / path / targetRevision   (Git)   — or chart/helm/kustomize
  ├── destination   WHERE it gets applied
  │     server (cluster API) + namespace
  ├── project       WHICH AppProject governs it (allowed repos/dests/resources)
  └── syncPolicy    HOW reconciliation behaves (manual/auto, prune, selfHeal)
```

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: web
  namespace: argocd                      # Applications live in the argocd ns
  finalizers:
    - resources-finalizer.argocd.argoproj.io   # cascade-delete managed resources on app delete
spec:
  project: dojo
  source:
    repoURL: https://github.com/CodeAadarsh/dojo-gitops.git
    targetRevision: main                 # branch, tag, or commit SHA (pin for prod!)
    path: apps/web/overlays/prod         # directory in the repo (Kustomize overlay here)
  destination:
    server: https://kubernetes.default.svc   # the in-cluster API; or a registered remote
    namespace: dojo-gitops
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true             # ArgoCD creates the destination namespace
      - ApplyOutOfSyncOnly=true          # only touch resources that actually differ
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

> **Pin `targetRevision` for anything real.** `main` means "whatever HEAD is right now" — an unrelated merge can change your prod cluster. Point prod at an immutable tag or a signed commit SHA and promote by bumping that reference in a PR. `HEAD`/branch tracking is fine for dev, dangerous for prod.

The **AppProject** (`kind: AppProject`) is the guardrail: it whitelists which `repoURL`s a team may deploy from, which destination clusters/namespaces they may target, and which resource kinds they may create (e.g. "no `ClusterRole`, no `ResourceQuota`"). Multi-tenant clusters live or die on good AppProjects — without them, any Application can deploy anything anywhere.

> **Gotcha — the `finalizer` is a double-edged sword.** `resources-finalizer.argocd.argoproj.io` makes `kubectl delete application web` cascade-delete every workload the app manages. Omit it and deleting the Application orphans its resources (they keep running, now unmanaged). Add it *and* have `prune` surprises, and a single `kubectl delete app` can wipe a namespace of live traffic. Know which one you've got before you delete anything.

---

## Sync policies: manual vs automated, selfHeal, prune

Two independent axes decide how aggressive reconciliation is.

| Setting | Off (default) | On |
|---------|---------------|-----|
| `automated` | You click **Sync** (or `argocd app sync`) | Controller syncs automatically when Git changes |
| `selfHeal` | Live drift is *reported* but left alone | Live drift is *reverted* to match Git |
| `prune` | Resources deleted from Git are *left orphaned* in the cluster | Resources removed from Git are deleted from the cluster |

Read those three carefully, because they interact in ways that surprise people:

- **`automated` without `selfHeal`** syncs on *Git* changes but ignores *cluster* changes. A `kubectl edit` drift is shown as OutOfSync and sits there until the next Git commit triggers a sync.
- **`selfHeal: true`** is what makes manual `kubectl edit` pointless — the controller detects the diff within its reconcile interval (default ~3 min, or instantly via webhook) and reapplies Git. This is the feature that actually enforces "Git is the source of truth."
- **`prune: true`** is off by default *on purpose* — auto-deleting resources is scary. Without it, deleting a manifest from Git leaves the live object orphaned (ArgoCD marks it as requiring prune but won't act). Turn it on so your cluster doesn't accumulate zombie resources, but understand it means a bad `git rm` deletes live workloads.

```bash
argocd app sync web                 # manual sync
argocd app set web --self-heal      # flip selfHeal on
argocd app diff web                 # show live-vs-desired before syncing
argocd app history web              # every synced revision — your rollback menu
argocd app rollback web 42          # roll back to a previous deploy id
```

> **`selfHeal` vs. a live incident.** During an outage you might `kubectl scale` a Deployment up to ride out load. With `selfHeal: true`, ArgoCD will scale it *back down* to the Git value within minutes. The correct muscle memory is: commit the change to Git, or temporarily disable auto-sync (`argocd app set web --sync-policy none`). Fighting the controller by hand always loses.

> **Gotcha — fields you *expect* to drift need `ignoreDifferences`.** If an HPA owns `spec.replicas` but your Git manifest also specifies `replicas: 3`, ArgoCD and the HPA will fight: the HPA scales to 7, ArgoCD (with selfHeal) yanks it back to 3, the HPA scales up again — a reconcile loop that thrashes your workload. The fix is to drop `replicas` from the manifest *and* add an `ignoreDifferences` for `/spec/replicas` so ArgoCD stops treating HPA-driven changes as drift. The same applies to anything a mutating webhook injects (Istio sidecars, defaulted fields).

---

## Drift detection: the health vs. sync distinction

ArgoCD tracks **two orthogonal statuses** for every Application, and conflating them causes bad on-call decisions:

```
   SYNC STATUS  →  does live state match Git?        { Synced | OutOfSync | Unknown }
   HEALTH STATUS →  are the resources actually OK?    { Healthy | Progressing | Degraded | Missing | Suspended }
```

They're independent:

| Sync | Health | What it means |
|------|--------|---------------|
| Synced | Healthy | The happy path — cluster matches Git and workloads are up |
| Synced | Degraded | You deployed exactly what Git says, and it's **broken** (crashloop, failing probe). Git is wrong — roll back the commit |
| OutOfSync | Healthy | Live state drifted (or Git moved ahead) but things still run. Sync to converge |
| OutOfSync | Missing | Git declares a resource that doesn't exist yet — needs a sync to create it |

The lesson: **"Synced" does not mean "working."** A green sync badge next to a `Degraded` health badge means the pipeline faithfully delivered a broken state. ArgoCD derives health from built-in rules (a Deployment is Healthy when `readyReplicas` meets spec, Progressing during a rollout, Degraded when it times out) and you can extend it with custom Lua health checks for your CRDs.

---

## Scaling the pattern: app-of-apps, sync waves, and hooks

### App-of-apps

One Application whose `source` is a directory of *other* Application manifests. ArgoCD syncs the parent, which creates the children, which each sync their own workloads. This is how you bootstrap a whole cluster — ingress, cert-manager, monitoring, your apps — from a single root Application in Git.

```
root-app (Application)
   └── path points at a repo dir full of Application manifests
         ├── ingress-nginx     (Application)
         ├── cert-manager      (Application)
         ├── prometheus-stack  (Application)
         └── web               (Application)
```

`ApplicationSet` is the templated evolution of this: generate N Applications from a list, a Git directory glob, or a cluster list — e.g. "one `web` Application per registered cluster."

### Sync waves & hooks — ordering within a sync

By default ArgoCD applies everything in a sync roughly together. When order matters (a database migration must finish before the app rolls, a CRD must exist before its CR), you control sequencing with annotations:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"   # lower waves apply first (can be negative)
```

Resources are grouped by wave and applied lowest-to-highest; ArgoCD waits for each wave's resources to become Healthy before starting the next. **Hooks** are resources that run at a specific sync phase rather than as part of the steady state:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook: PreSync                 # PreSync | Sync | PostSync | SyncFail
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
```

`PreSync` hooks (a `Job` running a DB migration) complete before the main sync; `PostSync` hooks (a smoke test) run after; `SyncFail` hooks run only when a sync fails (alerting, cleanup). This is how you express "migrate, then deploy, then verify" declaratively instead of in a brittle CI script.

> **Gotcha — a wave that never goes Healthy stalls the whole sync.** ArgoCD blocks before the next wave until the current wave's resources report Healthy. If wave 0 contains a Job that hangs, or a Deployment whose probe never passes, waves 1+ never apply and the app sits in `Progressing` indefinitely — looking stuck when it's actually *waiting as designed*. The symptom and its real cause are one wave apart, so always read waves in order when a sync hangs.

---

## Debugging ArgoCD

GitOps failures are deceptive because the controller keeps *trying* — a broken app doesn't error out, it loops quietly in `OutOfSync` or `Progressing` while you assume "ArgoCD has it." Work from the Application status down to the rendered manifests to the live objects.

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Stuck **OutOfSync** forever, never converges | `automated` is off (manual sync), or a field keeps drifting (HPA/webhook owns it), or prune is needed but disabled | `argocd app diff` to see *what* differs; enable automated sync, add `ignoreDifferences`, or sync manually |
| Stuck **Progressing** forever | A resource never becomes Healthy — failing probe, a sync-wave Job that hangs, a PVC stuck `Pending` | `argocd app get web` to find the non-Healthy resource; then `kubectl describe`/`logs` that object |
| **ComparisonError** / "rpc error: failed to generate manifest" | `repo-server` can't render — bad Kustomize/Helm, missing chart dep, wrong `path`, plugin not installed | `kubectl -n argocd logs deploy/argocd-repo-server`; reproduce locally with `kustomize build` / `helm template` |
| **Unknown** sync status, "authentication required" | Repo creds missing/expired, private repo, wrong SSH host key, rotated token | `argocd repo list`; re-add with `argocd repo add`; check the repo-creds Secret |
| selfHeal **reverts your hotfix** within minutes | `selfHeal: true` is doing its job — your `kubectl edit` is drift to it | Commit the fix to Git, or `argocd app set web --sync-policy none` for the duration of the incident |
| A live resource **vanished** after a Git change | `prune: true` + someone removed/renamed the manifest (or changed a `name`/label ArgoCD tracks by) | `argocd app history`; `git revert` the offending commit; re-sync to recreate |
| App **won't delete**, stuck `Terminating` | The `resources-finalizer` is waiting on a child resource that itself won't delete (stuck finalizer, PDB blocking) | `kubectl -n argocd get app web -o yaml` to see the finalizer; clear the blocked child first |
| "**another operation is already in progress**" | A previous sync is wedged mid-operation | `argocd app terminate-op web`, then re-sync |

Diagnose each with these — start at the top, stop when it tells you something:

```bash
# 1. The one-screen status: sync status, health, and EVERY resource's own health
argocd app get web
kubectl -n argocd get application web -o jsonpath='{.status.sync.status}{"  "}{.status.health.status}{"\n"}'

# 2. What actually differs between live and desired (the OutOfSync "why")
argocd app diff web
kubectl -n argocd get application web -o jsonpath='{range .status.resources[*]}{.kind}/{.name}  {.status}  {.health.status}{"\n"}{end}'

# 3. Rendering failures (ComparisonError) live in the repo-server, not the controller
kubectl -n argocd logs deploy/argocd-repo-server --tail=100
kustomize build apps/web/overlays/prod       # reproduce the exact render locally
helm template web ./chart -f values-prod.yaml # same, for Helm sources

# 4. Reconcile / sync decisions live in the application-controller
kubectl -n argocd logs statefulset/argocd-application-controller --tail=100 | grep -i web

# 5. Repo auth
argocd repo list                             # STATUS column must say "Successful"
kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository

# 6. Force a fresh comparison (bypass the cached manifest) and unwedge a stuck op
argocd app get web --refresh --hard-refresh
argocd app terminate-op web
```

### A worked ComparisonError

Symptom: the app flips to `ComparisonError`, the UI shows no resources, and `argocd app diff` prints nothing useful. Walk it from the render outward:

```bash
# 1. The controller only knows "comparison failed" — the real error is in repo-server:
kubectl -n argocd logs deploy/argocd-repo-server --tail=50 | grep -i -E 'error|failed'
#   → "Manifest generation error: kustomize build ... accumulating resources:
#      file 'apps/web/overlays/prod/configmap.yaml' doesn't exist"

# 2. Reproduce the EXACT render locally — repo-server runs this same command:
git -C dojo-gitops checkout "$(argocd app get web -o jsonpath='{.spec.source.targetRevision}')"
kustomize build dojo-gitops/apps/web/overlays/prod
#   → same error. The overlay references a file a recent PR renamed but didn't update in kustomization.yaml.

# 3. Fix in Git (not the cluster), push, then force a fresh comparison:
argocd app get web --refresh --hard-refresh
```

The discipline: a `ComparisonError` is **never** a cluster problem — nothing was applied, nothing drifted. It's always "the `repo-server` could not turn your Git revision into YAML." Reproduce the render locally with the *same* `kustomize build` / `helm template` the `repo-server` runs, and the error is in your hands in seconds instead of guessing at live state.

> **Gotcha — Helm `values` drift is invisible to `git log`.** When your source is a Helm chart with inline `spec.source.helm.values`, two things can change the rendered output without any commit to your app directory: the upstream chart version (if `targetRevision` tracks a range) and a values override edited in the ArgoCD UI (which lives in the Application object, *not* Git). An app can go `OutOfSync` or change behavior with a clean `git log` on the manifests. Keep values in Git-tracked files and pin the chart version, or you've reintroduced exactly the drift GitOps was supposed to kill.

> **War story.** A platform team pointed ~40 Applications at `targetRevision: main` with `selfHeal` and `prune` on — "pure GitOps, no snowflakes." A developer opened a PR that *moved* a service into a new subdirectory and renamed the Kustomize base. The diff looked clean in review. On merge, ArgoCD saw the old `path`'s resources as "no longer declared," pruned them — deleting the live Deployment and its Service — then created the renamed ones, which pulled a fresh image that hadn't finished building in the registry. Result: a 6-minute hole in a payments service, invisible in the PR because *the manifests were correct* — it was the prune-then-recreate ordering that bit. Two fixes came out of the postmortem: pin prod to **immutable tags** (never `main`), and set `prune: false` on the tier-0 apps so a destructive change surfaces as OutOfSync and *waits for a human* instead of executing itself. The lesson: `selfHeal + prune + branch-tracking` is a loaded gun pointed at prod, and the safety is pinning the revision.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Explain the pull model and why keeping cluster credentials *inside* the cluster (vs. in CI) is a security win.
2. Name the three parts of an `Application` spec (`source`, `destination`, `project`) and what each controls, and say why you pin `targetRevision` in prod.
3. Describe exactly what `prune`, `selfHeal`, and `automated` each do — and what `automated: {selfHeal: false}` ignores.
4. Explain why `Synced + Degraded` is a real state, what it means, and why "Synced" is not "working."
5. Use sync waves and a `PreSync` hook to express "run the DB migration, then roll the app."
6. Given an app stuck `OutOfSync` and another stuck `Progressing`, say which command you run first and which component's logs each points you at (`repo-server` for ComparisonError, `application-controller` for reconcile).
7. Explain the HPA-vs-selfHeal reconcile loop and how `ignoreDifferences` on `/spec/replicas` stops it.
8. Describe how `prune: true` + branch-tracking can delete live workloads from a "clean" PR, and the two config changes that defuse it.

➡ Next up: **Observability** — logs, metrics, and the LGTM stack. You run 100GB+/day of this at work; we'll pin down the data models, PromQL, golden signals, and the cardinality math that decides whether your bill is sane.
