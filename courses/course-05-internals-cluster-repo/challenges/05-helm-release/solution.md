# Solution — Package It With Helm

Two fully-accepted paths. Both end with a release named `web` in `dojo-helm`.

## Path A — scaffold a local chart (recommended)

`helm create` stamps out a complete, working chart (an nginx Deployment + Service + ServiceAccount + probes + HPA template):

```bash
helm create web
# web/
#   Chart.yaml        name + version + appVersion
#   values.yaml       the knobs (replicaCount, image, service, resources, probes)
#   templates/        the parameterized manifests (deployment.yaml, service.yaml, ...)
#   templates/_helpers.tpl   label + name helpers

# See exactly what will be applied BEFORE touching the cluster:
helm template web ./web -n dojo-helm --set image.tag=1.27-alpine | less

# Install as release 'web':
helm install web ./web -n dojo-helm --set image.tag=1.27-alpine
kubectl -n dojo-helm rollout status deploy/web
```

`helm template` (client-side render, no cluster write) is the Helm equivalent of `kubectl --dry-run=client -o yaml` — always eyeball the rendered output before an install or upgrade.

## Path B — install from a repo

Classic repo:

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm install web bitnami/nginx -n dojo-helm \
  --set image.tag=1.27-alpine --set replicaCount=1
```

Or an OCI chart (OCI registries are the modern distribution mechanism — a chart is just an OCI artifact alongside your images):

```bash
helm install web oci://registry-1.docker.io/bitnamicharts/nginx -n dojo-helm
```

Any chart works as long as the release is named `web` and its Deployment/StatefulSet carries the standard `app.kubernetes.io/instance=web` label (every well-formed chart sets this via `_helpers.tpl`).

## Verify

```bash
helm -n dojo-helm list                 # STATUS deployed, your chart + app version
kubectl -n dojo-helm get deploy -l app.kubernetes.io/instance=web
bash courses/course-05-internals-cluster-repo/challenges/05-helm-release/verify.sh
```

## Drive the lesson home — upgrade and roll back

This is the payoff Helm exists for. Watch the revision history grow and shrink:

```bash
helm upgrade web ./web -n dojo-helm --set replicaCount=3        # rev 2
helm history web -n dojo-helm                                   # 1 install, 2 upgrade

helm upgrade web ./web -n dojo-helm --set image.tag=1.27        # rev 3
helm rollback web 2 -n dojo-helm                                # rev 4 == contents of rev 2
helm history web -n dojo-helm
```

`rollback` does not "undo" — it re-applies the exact rendered manifests of the target revision and records that as a *new* revision. Your history is append-only and auditable, which is precisely what a folder of hand-edited YAML can never give you.

## Where the state actually lives

```bash
kubectl -n dojo-helm get secret -l owner=helm
# sh.helm.release.v1.web.v1 ... v2 ... v3 ...  (one Secret per revision)
```

Helm 3 has **no server-side component** (no Tiller). `helm` is a client that renders locally and applies as *you*; each release revision is persisted as a `helm.sh/release.v1` Secret in the release namespace. Consequences worth internalizing:

- Helm's RBAC is *your* RBAC — if you can't create a Deployment, neither can `helm install`.
- Delete those Secrets and you orphan the release: the objects keep running, but `helm list` forgets it and `rollback` is gone. Never hand-delete them.
- Because state is namespaced Secrets, two releases named `web` in *different* namespaces are completely independent.

## Debugging Helm installs — failure modes

| Symptom | Likely cause | Diagnose / fix |
|---------|--------------|----------------|
| `Error: INSTALLATION FAILED: ... already exists` | a release with that name exists, or leftover objects from a failed install | `helm list -n dojo-helm`; `helm uninstall web -n dojo-helm`; or `helm upgrade --install web ...` (idempotent) |
| release shows `STATUS: failed`, pods never came up | bad values / image / schema; install rolled back | `helm status web -n dojo-helm`; `helm get manifest web -n dojo-helm` to see what it tried to apply; fix values, re-run |
| pods `ImagePullBackOff` | `image.tag` points at a non-existent tag | `kubectl -n dojo-helm describe pod <p>`; re-install with a real tag (`--set image.tag=1.27-alpine`) |
| `UPGRADE FAILED: ... field is immutable` | you changed an immutable field (e.g. a Service clusterIP, a selector) | `helm diff upgrade` (plugin) to preview; some changes need uninstall+install, not upgrade |
| `helm list` empty but pods are running | release Secrets deleted, or you're in the wrong namespace | always pass `-n dojo-helm`; check `kubectl -n dojo-helm get secret -l owner=helm` |
| `Error: Kubernetes cluster unreachable` | wrong kube-context / cluster down | `kubectl config current-context` (want `kind-dojo`); `kubectl get ns` |

```bash
# the three commands that explain almost any failed release:
helm status web -n dojo-helm                 # phase + notes + last deployed
helm get values web -n dojo-helm             # the values actually in effect
helm get manifest web -n dojo-helm | head    # the exact YAML Helm rendered and applied
```

> **War story.** A team ran `helm upgrade` in CI with `--atomic` and a 5-minute timeout against a chart whose new version added a readiness probe the app couldn't yet satisfy. The probe never went green, the upgrade timed out, and `--atomic` dutifully **rolled the whole release back** to the previous revision — correct behavior. But the CI step also deleted the release's history Secrets in a misguided "cleanup" `kubectl delete secret -l owner=helm` afterwards. The app kept serving (the old pods were fine), so nobody noticed until the *next* deploy: `helm upgrade` had no revision 1 to diff against, treated it as a fresh install, and collided with the still-running objects — `INSTALLATION FAILED: ... already exists`. The lesson: Helm's release history is production state, not scratch data. Let `--atomic` do its job, set a timeout longer than your readiness, and never touch the `owner=helm` Secrets by hand.

## Hardening preview

- **Lint and template in CI** (`helm lint`, `helm template | kubeconform`) so a broken chart fails the pipeline, not the cluster.
- **Pin chart versions** (`--version`) *and* image tags — "latest chart, latest image" reintroduces exactly the drift Helm removes.
- **Sign and verify** charts (`helm package --sign`, `helm install --verify`) when pulling from external repos; an OCI chart is an unaudited bundle of manifests that run with your RBAC.
