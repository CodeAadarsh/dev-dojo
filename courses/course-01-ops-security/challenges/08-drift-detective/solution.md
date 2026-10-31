# Solution — Drift Detective

The fix is a one-field change: flip `spec.syncPolicy.automated.selfHeal` from `false` to `true`. Once it's on, Argo CD's reconciliation loop sees that the live `guestbook-ui` replica count (4) no longer matches Git (1), and re-applies Git — scaling it back to 1 and flipping the app to `Synced`.

## Step 1 — confirm the diagnosis

```bash
# The app knows it's drifted — it just isn't acting on it:
kubectl -n argocd get application drift-detective \
  -o jsonpath='{.status.sync.status}{"\n"}'          # -> OutOfSync

# self-heal is the reason it's sitting still:
kubectl -n argocd get application drift-detective \
  -o jsonpath='{.spec.syncPolicy.automated.selfHeal}{"\n"}'   # -> false

# the live drift itself:
kubectl -n dojo-drift get deploy guestbook-ui        # READY 4/4, Git says 1
```

## Step 2 — enable self-heal

Any of these work; pick one.

**Argo CD CLI (clean):**

```bash
argocd app set drift-detective --self-heal
```

**kubectl patch (no CLI, declarative-ish):**

```bash
kubectl -n argocd patch application drift-detective --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true}}}}'
```

**Or edit the manifest in Git and re-apply** (the true GitOps way — the Application itself should be version-controlled):

```yaml
# drift-detective-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: drift-detective
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps
    path: guestbook
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: dojo-drift
  syncPolicy:
    automated:
      prune: true
      selfHeal: true        # <- the one change that matters
    syncOptions:
      - CreateNamespace=true
```

```bash
kubectl apply -f drift-detective-app.yaml
```

## Step 3 — watch it reconcile, then verify

```bash
# within a few seconds the controller re-applies Git and scales back to 1:
kubectl -n dojo-drift get deploy guestbook-ui -w      # READY returns to 1/1
kubectl -n argocd get application drift-detective \
  -o jsonpath='{.status.sync.status}{"\n"}'           # -> Synced

bash courses/course-01-ops-security/challenges/08-drift-detective/verify.sh
```

## Why this is the right mental model

- **`automated` is not one switch, it's two.** `prune` governs what happens when a resource *leaves Git* (delete the orphan). `selfHeal` governs what happens when the *cluster drifts* from Git (re-apply Git). The setup had `prune: true, selfHeal: false`, which is exactly "notice drift, do nothing" — the app shows `OutOfSync` as a *report*, not as an *action*.
- **Why Argo CD deliberately leaves drift alone by default.** Reverting a human's live change automatically is a strong, sometimes dangerous behavior — it will undo an operator's emergency fix seconds after they make it. Argo CD makes you opt in to that enforcement precisely because it changes who wins the tug-of-war between a human with `kubectl` and the controller.
- **Reconciliation is a loop, not an event.** With `selfHeal: true`, drift isn't fixed once — it's fixed *every time it recurs*. Try `kubectl -n dojo-drift scale deploy guestbook-ui --replicas=7` now and watch it snap back within seconds. That's the property you actually want in production: the cluster is self-correcting.

## Operator's note — the break-glass tension

Self-heal is the behavior you want 99% of the time and the behavior you must be able to *suspend* during the other 1%. When you genuinely need to hold a manual state during an incident, don't fight the controller — disable auto-sync explicitly (`argocd app set drift-detective --sync-policy none`), make your change, then restore the policy and reconcile via Git afterward. Fighting a self-healing controller by hand is an unwinnable, log-spamming loop. Knowing *how to turn it off on purpose* is as much a part of operating GitOps as knowing how to turn it on.
