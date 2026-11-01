# Solution: GitOps Handoff

## application.yaml

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dojo-gitops-handoff
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: dojo-cicd-gitops
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

Apply it:

```bash
kubectl apply -f ~/.kube-dojo-work/06-gitops-handoff/application.yaml -n argocd
# Wait for convergence:
kubectl -n argocd get application dojo-gitops-handoff -w
# STATUS field should show: Synced / Healthy within ~60s
```

## Why each field matters

**`spec.source.repoURL + path`** — the Git address ArgoCD polls. In a real
CI/CD pipeline, CI commits an updated image tag to this path; ArgoCD detects
the diff and reconciles. The `targetRevision: HEAD` means the Application always
tracks the branch tip. Pin to a specific branch or tag in production:
`targetRevision: main` or `targetRevision: v1.2.3`.

**`spec.destination.server: https://kubernetes.default.svc`** — the in-cluster
API server address. ArgoCD uses its own service account to talk to this
endpoint. For multi-cluster setups, register the target cluster in ArgoCD and
use its registered URL here.

**`spec.syncPolicy.automated`** — the key field the verifier checks. Without it,
ArgoCD shows drift in the UI but does nothing about it. `prune: true` means
ArgoCD deletes cluster resources that no longer exist in Git (safe for CD;
controversial in shared namespaces). `selfHeal: true` means any out-of-band
`kubectl apply` that diverges from Git is reverted by ArgoCD within the sync
interval (~3 minutes by default). These two settings are what makes the cluster
a read-only projection of Git.

**`CreateNamespace=true`** — ArgoCD creates `dojo-cicd-gitops` if it doesn't
exist when syncing. Omit this if your namespace is managed separately (e.g.,
provisioned by Crossplane or Terraform) to keep ArgoCD from owning it.

## The CI/CD boundary in practice

At SAP AI Core (or any large platform), the boundary is enforced at the
infrastructure level:

| Side | What it holds |
|------|--------------|
| CI (GitHub Actions) | Docker Hub push credentials, test env secrets, nothing more |
| CD (ArgoCD) | In-cluster RBAC, namespace creation rights, image pull secrets |

A GitHub Actions runner never has a kubeconfig. It commits to the GitOps repo
and its job is done. ArgoCD watches the repo; when it sees a new commit, it
reconciles. This separation means a stolen CI token cannot directly modify
production — the attacker would also need write access to the GitOps repo, and
even then ArgoCD's audit log would show the reconciliation event.

## Triggering sync manually (when automated sync has a delay)

```bash
# Force an immediate sync without waiting for the poll interval
kubectl -n argocd patch application dojo-gitops-handoff \
  --type merge \
  -p '{"operation": {"initiatedBy": {"username": "admin"}, "sync": {"revision": "HEAD"}}}'

# Or install the ArgoCD CLI and use:
# argocd app sync dojo-gitops-handoff
```

## Hardening preview

```yaml
# In production: restrict what ArgoCD can modify with an AppProject
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: cicd-apps
  namespace: argocd
spec:
  sourceRepos:
  - 'https://github.com/your-org/gitops-manifests.git'  # allowlist
  destinations:
  - namespace: dojo-cicd-gitops
    server: https://kubernetes.default.svc
  clusterResourceWhitelist: []  # no cluster-scoped resources
  namespaceResourceBlacklist:
  - group: ''
    kind: ResourceQuota   # ArgoCD cannot modify quotas
```

An AppProject scopes what repos an Application can pull from, what namespaces
it can deploy to, and what resource kinds it can manage — least privilege for
the GitOps controller itself.
