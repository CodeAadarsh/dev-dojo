# Solution — ApplicationSet — Multi-Env GitOps

One manifest. Apply it to the `argocd` namespace after ArgoCD is running.

```yaml
# dojo-appset.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: dojo-environments
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - env: dev
            repoPath: charts/dojo-app
          - env: staging
            repoPath: charts/dojo-app
  template:
    metadata:
      name: 'dojo-{{env}}'
      labels:
        app.kubernetes.io/managed-by: dojo-appset
    spec:
      project: default
      source:
        repoURL: https://github.com/example/dojo-app.git
        targetRevision: HEAD
        path: '{{repoPath}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: dojo-appset
      syncPolicy:
        syncOptions:
          - CreateNamespace=true
```

Apply and verify:

```bash
kubectl apply -f dojo-appset.yaml
bash courses/course-09-platform-engineering/challenges/06-applicationset/verify.sh
```

The generated Applications (`dojo-dev`, `dojo-staging`) will appear in ArgoCD but show `Unknown` or `Missing` sync status — there's no real chart at the repoURL. That's expected. The verifier only checks the ApplicationSet object's structure.

## Why each piece matters

**List generator — the simplest generator.** A list generator is just a YAML array of key-value maps. Every entry produces one Application, with the map's keys available as `{{key}}` substitutions in the template. You can add a third environment by adding one element — no new Application manifest, no copy-paste.

**`destination.server: https://kubernetes.default.svc`.** This is the in-cluster API server address. In a single-cluster setup it's the only server available. In multi-cluster ArgoCD, you'd register external clusters and reference them by their registered URL (or use the cluster generator which discovers registered clusters automatically).

**`syncPolicy.syncOptions: CreateNamespace=true`.** Without this, ArgoCD will error if `dojo-appset` doesn't already exist when it first tries to sync. With it, ArgoCD creates the namespace as part of sync. The `setup.sh` for this challenge pre-creates it, but this flag is a good default for real ApplicationSets.

**`metadata.labels` on the template.** Labels on generated Applications are how you filter and manage them as a group: `kubectl -n argocd get applications -l app.kubernetes.io/managed-by=dojo-appset`. Without them, differentiating generated Applications from hand-crafted ones requires reading the `ownerReferences`.

## The scaling progression

Once you're comfortable with the list generator:

| Generator | When to use |
|-----------|------------|
| `list` | Fixed, small set of environments known at authoring time |
| `clusters` | Enumerate all clusters registered in ArgoCD by label |
| `git` (dirs) | One app per subdirectory in a repo — `apps/frontend`, `apps/backend` become separate Applications automatically |
| `git` (files) | Parametrize from JSON/YAML files committed in the repo (config-as-code) |
| `matrix` | Cross-product of two generators: all clusters × all apps |
| `merge` | Combine generators with override semantics (base + per-env patch) |

## Attacker's view

An ApplicationSet with a permissive generator and `project: default` (which has no restrictions) can be used to deploy to any namespace in the cluster. In a shared ArgoCD installation, restrict ApplicationSets with AppProject policies: set `spec.project` to a project that limits allowed source repos, destination namespaces, and cluster resources. An ApplicationSet that can write to `kube-system` is a privilege escalation path.
