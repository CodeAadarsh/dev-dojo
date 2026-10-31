# Solution — GitOps or It Didn't Happen

One manifest does the whole job. Author it, apply it, let Argo CD reconcile.

## The Application

```yaml
# guestbook-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd                 # the Application object lives in argocd...
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps
    path: guestbook
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc   # ...but it deploys in-cluster...
    namespace: dojo-gitops                    # ...into this namespace.
  syncPolicy:
    automated:
      prune: true                   # delete resources that disappear from Git
      selfHeal: true                # revert manual drift back to Git
    syncOptions:
      - CreateNamespace=true        # create dojo-gitops if it's somehow absent
```

Apply and watch it converge:

```bash
kubectl apply -f guestbook-app.yaml

# with the Argo CD CLI (optional but the clean way to force + wait):
argocd app sync guestbook
argocd app wait guestbook --health

# pure kubectl, no CLI:
kubectl -n argocd get application guestbook \
  -o jsonpath='{.status.sync.status}{" / "}{.status.health.status}{"\n"}'
# -> Synced / Healthy
```

Then run the verifier:

```bash
bash courses/course-01-ops-security/challenges/07-gitops-or-it-didnt-happen/verify.sh
```

## Why each piece is correct

- **`metadata.namespace: argocd`** — the `Application` is a custom resource that the Argo CD controllers watch, and by default they only watch their own namespace. Put the object anywhere else and the controller never sees it. This is the #1 beginner mistake: confusing *where the Application object lives* (`argocd`) with *where it deploys* (`spec.destination.namespace`).
- **`destination.server: https://kubernetes.default.svc`** — the well-known in-cluster API endpoint Argo CD registers as `in-cluster`. You could equally use `name: in-cluster`, but the server URL is unambiguous and doesn't depend on the cluster's registered name.
- **`syncPolicy.automated`** — without it the app is created `OutOfSync` and sits there until you manually sync. `prune: true` lets Argo CD *delete* resources you removed from Git (without it, deletions in Git leak orphaned objects in the cluster forever). `selfHeal: true` makes Argo CD actively revert any `kubectl edit` someone does behind its back — that's the "or it didn't happen" enforcement.
- **`CreateNamespace=true`** — harmless here since `setup.sh` already made `dojo-gitops`, but it's the right habit: it lets the Application own namespace creation so the whole deployment is self-contained in Git.

## The attacker's / operator's view

`selfHeal: true` is a double-edged sword worth respecting. It is exactly what you want against accidental drift — but it also means that during an incident, your emergency `kubectl scale` or `kubectl edit` will be **silently reverted within seconds** by the controller. Operators who don't know the app is GitOps-managed burn real minutes fighting a controller that keeps undoing them. The correct break-glass move is to change Git (or temporarily disable auto-sync: `argocd app set guestbook --sync-policy none`), never to fight the reconciler. That tension — self-heal vs. break-glass — is exactly what the next challenge, **Drift Detective**, makes you feel on purpose.

## Hardening preview

In production you'd tighten this further: pin `targetRevision` to a tag or commit SHA (never `HEAD`) so a sync is reproducible and can't pull a surprise upstream commit; scope the `AppProject` to an allow-list of repos, destinations, and resource kinds instead of the wide-open `default` project; and add `syncOptions: ApplyOutOfSyncOnly=true` plus sync windows for change-controlled environments.
