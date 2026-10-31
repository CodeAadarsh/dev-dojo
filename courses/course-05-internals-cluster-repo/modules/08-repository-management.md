# Repository Management: Registries, Helm & GitOps Repos

> **Module 08 · Course 05** — A cluster is only as trustworthy as the artifacts you feed it. This module covers the three repositories every real deployment pipeline leans on: the **container registry** that holds your images, the **Helm/chart repo** that packages your workloads, and the **Git repo** that declares your cluster's desired state. The competent engineer `docker push`es and `helm install`s. The expert pins by **digest**, knows why a `helm upgrade` wedges into `pending-upgrade` and how to un-wedge it, and structures a GitOps repo so a new environment is a directory, not a rewrite.

You push images and run Helm charts at work. What separates expert from competent here is the failure modes: an `ImagePullBackOff` that's really an auth problem, a Helm release stuck mid-upgrade with no obvious rollback, and a Kustomize overlay that silently applies the base because a patch target didn't match. We'll reproduce each on the `kind` dojo.

---

## Container registries: tags lie, digests don't

A registry stores images addressed two ways, and the difference is a production-correctness issue, not a style preference:

| Reference | Example | Mutable? | Use for |
|-----------|---------|:--------:|---------|
| **Tag** | `nginx:1.27-alpine` | **yes** — the owner can re-push the same tag | humans, dev, "track this minor" |
| **Digest** | `nginx@sha256:a1b2…` | **no** — content-addressed, immutable | prod, GitOps, anything auditable |

A tag is a *pointer*; the registry owner can move it. `nginx:1.27-alpine` today and after a re-push are different bytes with the same name — which is exactly how a "we didn't change anything" deploy ships a new image. The digest is the SHA-256 of the manifest, so `nginx@sha256:…` is *the same bytes forever*. Find and pin it:

```bash
# the digest your cluster actually pulled (resolved, not the tag you asked for)
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].imageID}{"\n"}'
# -> docker.io/library/nginx@sha256:...

# resolve a tag to its digest without running it
docker buildx imagetools inspect nginx:1.27-alpine | grep -i digest
```

> **The `:latest` trap, concretely.** `:latest` is just a conventional tag with no special meaning — it is *not* "the newest version," it's "whatever was pushed last." Combined with the default `imagePullPolicy` (which is `Always` for `:latest`, `IfNotPresent` for any other tag), `:latest` gives you non-reproducible rollouts: two pods of the same Deployment can run different code because they pulled `:latest` at different minutes. Every image in this dojo is pinned to a real tag for exactly this reason. In prod, pin to a **digest**.

**Garbage collection.** Registries never reclaim space on their own. Deleting a tag only unlinks it; the underlying blobs stay until a GC pass runs (`registry garbage-collect` for the reference `registry:2`, or the GC job on Harbor/ECR/GCR/GAR lifecycle policies). Untagged "dangling" layers from overwritten tags are the usual disk hog.

**Pull secrets.** Private registries need credentials, delivered as a `kubernetes.io/dockerconfigjson` Secret and referenced by `imagePullSecrets` — on the pod directly or (cleaner) attached to the ServiceAccount so every pod inherits it:

```bash
kubectl -n dojo-apps create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username='robot$ci' --docker-password="$TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# attach to the SA so you don't repeat it on every pod
kubectl -n dojo-apps patch serviceaccount default \
  -p '{"imagePullSecrets":[{"name":"regcred"}]}'
```

### A local registry for kind

`kind` nodes have their **own** image store, isolated from your host Docker — a locally built image is invisible to the cluster until you make it reachable. Two paths:

```bash
# Path A — one-off: copy an image straight into every node's store
docker build -t myapp:dev .
kind load docker-image myapp:dev --name dojo
docker exec dojo-control-plane crictl images | grep myapp   # confirm it landed on the node

# Path B — a real registry wired into the kind network (reference: labs/bootstrap/install-registry.sh)
bash labs/bootstrap/install-registry.sh                     # registry:2 at localhost:5001
docker tag myapp:dev localhost:5001/myapp:dev
docker push localhost:5001/myapp:dev
# then reference image: localhost:5001/myapp:dev in your manifests
```

`kind load` is fine for a single image during development; the local registry mirrors a real `docker push`/pull loop and is what you want when you're iterating on a GitOps flow that pulls by reference. Both are pinned to tags, never `:latest`.

---

## Helm: templating, releases, and the state you forget it keeps

Helm packages a set of manifests as a **chart**, renders it with **values**, and tracks each install as a **release** with a revision history. The vocabulary, precisely:

| Term | What it is |
|------|------------|
| **Chart** | a versioned bundle: `Chart.yaml` + `templates/` + default `values.yaml` |
| **Values** | the inputs that fill the template placeholders; layered: chart defaults < `-f file` < `--set` |
| **Release** | one named install of a chart into a namespace, with a numbered revision history |
| **Repo** | an index of charts — classic HTTP (`index.yaml`) or **OCI** (charts stored in a container registry) |

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami   # classic HTTP repo
helm repo update
helm search repo bitnami/redis --versions                  # chart versions available
helm install cache bitnami/redis -n dojo-apps --create-namespace \
  -f prod-values.yaml --set architecture=standalone        # values layer: file then --set wins
helm list -n dojo-apps                                     # releases + current revision + status
helm get values cache -n dojo-apps                         # the values THIS release was rendered with
helm history cache -n dojo-apps                            # every revision, for rollback targets
```

**Render before you ship.** `helm template` and `--dry-run` turn Helm from "magic that applies something" into a diff you can read:

```bash
helm template cache bitnami/redis -f prod-values.yaml | less        # the exact YAML, no cluster touched
helm upgrade cache bitnami/redis -f prod-values.yaml --dry-run      # server-validated render
helm diff upgrade cache bitnami/redis -f prod-values.yaml           # needs the helm-diff plugin — worth it
```

**OCI charts** store the chart *in a container registry* alongside images — one artifact store, one auth model, digest-pinnable like any image:

```bash
helm push ./mychart-0.1.0.tgz oci://localhost:5001/charts
helm install app oci://localhost:5001/charts/mychart --version 0.1.0 -n dojo-apps
```

**Dependencies.** A chart can depend on subcharts (declared in `Chart.yaml` under `dependencies`), vendored into `charts/` by `helm dependency update`. The gotcha: subchart values are namespaced under the subchart's name in *your* `values.yaml` (e.g. `redis: { auth: { enabled: false } }`), and a `helm dependency update` must run before `install` or the subcharts simply aren't there.

**Where Helm keeps release state.** This is the part people forget until it bites: Helm stores each release's manifest and revision history in a **Secret per revision**, in the release's namespace, type `helm.sh/release.v1`. That Secret *is* the release state — lose it and `helm` forgets the release exists.

```bash
kubectl -n dojo-apps get secret -l owner=helm           # sh.helm.release.v1.cache.v1, .v2, ...
```

---

## Structuring a GitOps repo

The GitOps repo is the cluster's real source of truth (Module 07's "intent" leg): a controller (Argo CD / Flux) continuously reconciles the cluster toward what's committed. The whole discipline is **no `kubectl apply` by hand** — you commit, the controller applies. Install Argo CD into the dojo to see it:

```bash
bash labs/bootstrap/install-argocd.sh    # Argo CD + the UI port-forward + initial admin password
```

### Per-environment overlays with Kustomize

Don't copy-paste a manifest per environment. Keep one **base** and thin **overlays** that patch it:

```
gitops/
  base/                      # the environment-agnostic truth
    deployment.yaml
    service.yaml
    kustomization.yaml       # resources: [deployment.yaml, service.yaml]
  overlays/
    dev/
      kustomization.yaml     # bases: [../../base]; replicas patch -> 1; image tag -> dev
    staging/
      kustomization.yaml     # replicas -> 2
    prod/
      kustomization.yaml     # replicas -> 5; image pinned by DIGEST; prod ConfigMap
```

An overlay's `kustomization.yaml` references the base and layers changes — a strategic-merge or JSON patch, image overrides, name prefixes, common labels:

```yaml
# overlays/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: dojo-apps
resources:
  - ../../base
replicas:
  - name: web
    count: 5
images:
  - name: web
    newName: localhost:5001/web
    digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
patches:
  - path: prod-resources.yaml      # bump requests/limits for prod only
    target:
      kind: Deployment
      name: web
```

```bash
kubectl kustomize gitops/overlays/prod        # render the fully-merged YAML — ALWAYS diff this
kubectl apply -k gitops/overlays/prod         # or let Argo CD do it from Git
```

### App-of-apps

For many services, one Argo CD `Application` ("the root app") points at a directory of *other* `Application` manifests — each of those points at a real overlay. Bootstrapping the whole platform becomes applying one root app; adding a service is committing one more `Application` file. It's a tree of pointers that turns "deploy the platform" into a single reconcile.

### Secrets in GitOps — never in plaintext

The one thing you cannot commit raw is a Secret. Two real answers:

| Approach | How it works | Trade-off |
|----------|--------------|-----------|
| **Sealed Secrets** (Bitnami) | you encrypt to a `SealedSecret` with the controller's public key; only the in-cluster controller can decrypt | the sealed blob is safe in Git; tied to one cluster's key |
| **SOPS** (+ age/KMS, via Flux or a plugin) | values encrypted in-file with a KMS/age key; decrypted at apply time | key management lives in your KMS; works across clusters |

Both keep **ciphertext in Git and plaintext only in the cluster**. The anti-pattern — a base64'd `Secret` committed to the repo — is Course 01's "base64 is not encryption" lesson all over again: base64 is encoding, and the repo history keeps it forever.

---

## Debugging registries, Helm & overlays

Artifact failures cluster into three families: the pull failed, the release wedged, or the overlay rendered something other than you meant. Triage table.

| Symptom | Likely cause | Fix / confirm |
|---------|--------------|---------------|
| Pod `ImagePullBackOff` / `ErrImagePull`, `describe` says `pull access denied` / `401` | missing or wrong `imagePullSecret`; private repo | check the pull secret is present and referenced (below) |
| `ImagePullBackOff` for a *local* kind image, `not found` | built on host; kind nodes never got it | `kind load docker-image <img> --name dojo` **or** push to `localhost:5001` |
| `ErrImagePull`: `manifest unknown` / `not found` | tag doesn't exist (typo, or GC'd), or wrong registry host | re-check the exact `image:` ref; `docker buildx imagetools inspect` it |
| `helm upgrade` fails and release sticks in `pending-upgrade` / `pending-install` | a prior upgrade was interrupted (Ctrl-C, timeout, OOM of the helm process) | `helm rollback` to the last good revision, or clean the stuck release secret (below) |
| `helm install`: `cannot re-use a name that is still in use` | a failed install left a release record behind | `helm uninstall <name>` then reinstall, or `--replace` |
| `helm upgrade` fails: `field is immutable` | changed an immutable field (e.g. a Deployment selector, a PVC size down) | revert the field, or delete+recreate the object the chart owns |
| `kubectl apply -k` applies the **base**, ignoring your patch | patch `target` (kind/name/namespace) doesn't match any resource — silent no-op | `kubectl kustomize` the overlay and diff; fix the target selector |
| Argo CD app stuck `OutOfSync` / `SyncFailed` | render error, a hook failing, or drift it can't reconcile | `argocd app diff <app>`; read the app's conditions/events |

### Diagnose each — the exact commands

**ImagePullBackOff from auth.** The events tell you *which* kind of pull failure it is; then confirm the secret is actually wired:

```bash
kubectl -n dojo-apps describe pod <pod> | sed -n '/Events:/,$p'   # 401/denied vs not found vs no secret
kubectl -n dojo-apps get pod <pod> -o jsonpath='{.spec.imagePullSecrets[*].name}{"\n"}'  # is a secret referenced?
kubectl -n dojo-apps get secret regcred -o jsonpath='{.type}{"\n"}'  # must be kubernetes.io/dockerconfigjson
# what the node actually tried to pull vs what it has:
kubectl -n dojo-apps get pod <pod> -o jsonpath='{.spec.containers[0].image}{"\n"}'
docker exec dojo-control-plane crictl images | grep <repo>
```

**Helm release stuck/failed + rollback.** Read the history, find the last `deployed` revision, roll back to it:

```bash
helm history cache -n dojo-apps                    # STATUS column: find the last "deployed" revision
helm status cache -n dojo-apps                      # current state; shows "pending-upgrade" if wedged
helm rollback cache <last-good-rev> -n dojo-apps    # atomic revert to a known-good revision
# if rollback itself refuses because the release is wedged mid-transaction, the state lives in a Secret:
kubectl -n dojo-apps get secret -l owner=helm,name=cache    # sh.helm.release.v1.cache.vN
# deleting the stuck *pending* revision secret lets helm see the prior good one (last resort, know what you drop)
```

Prefer `helm upgrade --atomic --timeout 5m` going forward: on failure it auto-rolls-back instead of leaving a `pending-upgrade` corpse.

**Kustomize/overlay mistakes.** The cardinal rule: **render, then diff — never apply blind.** A mistargeted patch is a silent no-op, so the only way to catch it is to look at the output:

```bash
kubectl kustomize gitops/overlays/prod | grep -E 'replicas:|image:'   # did the patch actually take?
diff <(kubectl kustomize gitops/overlays/dev) <(kubectl kustomize gitops/overlays/prod)  # envs should differ
kubectl apply -k gitops/overlays/prod --dry-run=server                # server-side validate before real apply
# Argo CD equivalent:
#   argocd app diff web-prod         # shows live vs desired before you sync
```

> **War story.** A platform team's `helm upgrade` of their ingress chart timed out because a pre-upgrade hook Job was waiting on a dependency that wasn't up yet. Someone hit Ctrl-C to "try again." That left the release in `pending-upgrade` — and every subsequent `helm upgrade` refused with `another operation (install/upgrade/rollback) is in progress`. Under pressure they `helm uninstall`-ed to "reset it," which **deleted the live ingress controller** and took down every app behind it cluster-wide — the thing they were trying to patch, now gone. The recovery was a `helm rollback` they could have run in the first thirty seconds, if they'd known the release's entire state was sitting in a `sh.helm.release.v1.*` Secret and that `pending-upgrade` means "an operation was interrupted," not "corrupted beyond repair." Two lessons burned in: **(1)** never Ctrl-C a Helm operation — use `--atomic --timeout` so a failure rolls itself back cleanly; **(2)** `helm uninstall` to "reset a stuck release" deletes the running workload. The stuck state is just a Secret; `helm history` + `helm rollback` is the actual fix.

---

## Checkpoint

You own this module when you can, without looking anything up:

1. Explain the tag-vs-digest difference, why `:latest` + the default pull policy gives non-reproducible rollouts, and pull the real digest a pod ran with from `.status.containerStatuses[].imageID`.
2. State why registries don't reclaim space automatically and what garbage collection actually removes.
3. Create a `dockerconfigjson` pull secret, attach it to a ServiceAccount, and diagnose an `ImagePullBackOff` as auth-vs-not-found by reading `describe pod` events.
4. Make a locally built image runnable on `kind` two ways — `kind load` and the `localhost:5001` registry — and say when you'd use each.
5. Define chart / values / release / repo, show the values layering order (defaults < `-f` < `--set`), and render a chart with `helm template` before shipping.
6. Explain that a Helm release's state lives in a per-revision Secret, diagnose a `pending-upgrade` release, and recover it with `helm rollback` (and why `--atomic` prevents the mess).
7. Lay out a Kustomize base + per-env overlays, explain app-of-apps, and catch a mistargeted patch by rendering with `kubectl kustomize` and diffing instead of applying blind.
8. Name two correct ways to keep Secrets in a GitOps repo (Sealed Secrets, SOPS) and why a base64'd committed Secret is not one of them.

➡ You've reached the operator's summit: internals, cluster lifecycle, and the repositories that feed it. Take these into the course challenges — the cluster is yours to run, break, and rebuild.
