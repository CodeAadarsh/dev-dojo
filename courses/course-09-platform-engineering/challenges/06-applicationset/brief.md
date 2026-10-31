# ApplicationSet — Multi-Env GitOps

Your team has a staging and production environment. The current setup has two nearly-identical ArgoCD `Application` objects that drift apart whenever someone updates one and forgets the other. During your last incident review, you found that prod was running a two-release-old chart because someone applied a hotfix manually to staging and never opened a PR.

The fix is an **ApplicationSet**: one object that templates N applications from a generator. When you add a new environment, you add one entry to a list — not a new Application manifest.

## Prereqs

**ArgoCD must be installed** before running setup.sh or verify.sh. If it isn't:

```bash
bash labs/bootstrap/install-argocd.sh
```

Wait for `argocd-server` to become ready:

```bash
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s
```

## Mission

Create an ArgoCD **ApplicationSet** in namespace `argocd` that:

1. Uses a **list generator** with at least **2 elements** (e.g., `dev` and `staging`).
2. Templates Applications whose `spec.destination.namespace` is `dojo-appset`.
3. Is well-formed — the ApplicationSet object must be accepted by the ArgoCD API.

The verifier checks **all** of the following:

- Namespace `argocd` exists and ArgoCD is installed (ApplicationSet CRD present).
- At least one ApplicationSet exists in namespace `argocd`.
- It has a non-empty `spec.generators` array.
- The template's `spec.destination.namespace` is `dojo-appset`.

> The generated Applications will likely fail to sync (they need a real git repo with chart content). That's expected and fine — the verifier only checks the ApplicationSet object's structure, not sync status.

```bash
bash courses/course-09-platform-engineering/challenges/06-applicationset/verify.sh
```

## Why this matters

| Approach | 3 envs | 10 envs |
|----------|--------|---------|
| One Application per env | 3 nearly-identical manifests, drift guaranteed | 10 manifests, a full-time copy-paste job |
| ApplicationSet (list generator) | 1 object, 3 list entries | 1 object, 10 list entries |
| ApplicationSet (cluster generator) | 1 object, auto-discovers clusters | Same — scales to 0 extra YAML per new cluster |

The list generator is the gateway drug. Once you've seen it, you reach for the cluster generator (enumerate all clusters from a label), the git generator (one app per subdirectory in a repo), and the matrix generator (cross-product of clusters × apps) without friction.

## ApplicationSet template syntax

ArgoCD ApplicationSet uses `{{param}}` (double braces) to substitute generator parameters:

```yaml
spec:
  generators:
    - list:
        elements:
          - env: dev
          - env: staging
  template:
    metadata:
      name: 'myapp-{{env}}'       # -> myapp-dev, myapp-staging
    spec:
      destination:
        namespace: dojo-appset
```

The double-brace syntax is ArgoCD's own — it has nothing to do with Helm's `{{ }}` or Go templates.
