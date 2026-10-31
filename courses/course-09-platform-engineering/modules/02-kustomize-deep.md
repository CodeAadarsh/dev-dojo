# Kustomize, Deeply

> **Module 02 · Course 09** — Kustomize is built into `kubectl apply -k` and ships with every Kubernetes distribution. It doesn't template — it *patches* structured YAML in place. Understanding exactly how the two patch types work, how generators produce objects with rolling-restart semantics, and how components avoid copy-paste across environments will save you from the subtle bugs that come from treating Kustomize as "simple Helm."

You've seen Kustomize overlays in GitOps repos and probably written a `kustomization.yaml`. This module covers what you haven't: why your JSON patch isn't landing, where name-suffix hashes break image pulls, and how to use components to share policy without duplication.

---

## Bases & overlays — the mental model

Kustomize has no variables. Instead it takes real Kubernetes objects (the **base**) and applies a set of mutations (an **overlay**) to produce the final manifests. The base is unmodified source-of-truth YAML; overlays are diff layers stacked on top:

```
infra/
  base/
    kustomization.yaml
    deployment.yaml
    service.yaml
  overlays/
    dev/
      kustomization.yaml      # references ../../base
      deployment-patch.yaml   # dev-specific mutations
    prod/
      kustomization.yaml
      deployment-patch.yaml   # prod-specific mutations (replicas, resources, etc.)
      hpa.yaml                # extra objects only in prod
```

```yaml
# base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml
```

```yaml
# overlays/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base
  - hpa.yaml            # prod-only extra object added to the DAG

patches:
  - path: deployment-patch.yaml
    target:
      kind: Deployment
      name: myapp
```

Preview what Kustomize will emit without applying it — always do this before `apply`:

```bash
kubectl kustomize overlays/prod                         # rendered YAML to stdout
kubectl kustomize overlays/prod | diff - <(kubectl kustomize overlays/dev)  # compare envs
kubectl apply -k overlays/prod --dry-run=server         # full server-side dry-run including admission
```

---

## Strategic-merge patches

Strategic-merge patch (SMP) is the "natural" Kubernetes patch type. It understands schema-defined list merge semantics — the API server's built-in knowledge of which field is the merge key for each list:

```yaml
# overlays/prod/deployment-patch.yaml  (strategic-merge)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  replicas: 5
  template:
    spec:
      containers:
        - name: app          # identifies which container to patch — this is the merge key
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 512Mi
          env:
            - name: LOG_LEVEL
              value: warn
```

SMP list behavior:
- **Maps are merged**, not replaced. Adding a key to a nested map keeps existing keys intact.
- **Container lists use `name` as the merge key.** Kustomize matches by name and merges the fields — it does not replace the whole container list.
- To **delete an item** in an SMP list, add `$patch: delete` alongside the merge key:

```yaml
# Delete a sidecar you inherited from the base:
spec:
  template:
    spec:
      containers:
        - name: datadog-agent
          $patch: delete
```

SMP is the right default for most Deployment/StatefulSet mutations. Switch to JSON 6902 when you need precise list-index operations or when the resource's schema doesn't define useful merge keys (custom CRDs).

---

## JSON 6902 patches

RFC 6902 patches are explicit operations on a JSON Pointer path — always precise, never schema-dependent:

```yaml
# overlays/prod/kustomization.yaml
patches:
  - target:
      kind: Deployment
      name: myapp
    patch: |
      - op: replace
        path: /spec/replicas
        value: 5
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value:
          name: ENV
          value: production
      - op: remove
        path: /spec/template/spec/containers/0/env/2
      - op: add
        path: /metadata/annotations/prometheus.io~1scrape
        value: "true"
```

Operations: `add`, `remove`, `replace`, `move`, `copy`, `test`.

Path syntax details:
- `/spec/template/spec/containers/0/env/-` — the trailing `-` appends to the array
- `/containers/0` — first container by index (zero-based); this breaks if the base reorders containers
- `~1` encodes a literal `/` in a key name (`prometheus.io/scrape` → `prometheus.io~1scrape`)
- `~0` encodes a literal `~`

**SMP vs JSON 6902 decision:**
- SMP for: modifying resources/replicas/env on a named container, adding volumes, setting affinity.
- JSON 6902 for: inserting/removing at a specific list index, patching CRDs without schema-defined merge keys, adding annotations that contain `/`.

---

## Generators: configMap and secret

Generators create ConfigMaps and Secrets from literals or files — and optionally append a content hash to the name, automatically triggering a rolling restart whenever the data changes:

```yaml
# kustomization.yaml
configMapGenerator:
  - name: app-config
    literals:
      - ENV=production
      - LOG_LEVEL=warn
    files:
      - config.properties          # file content becomes a key named "config.properties"

secretGenerator:
  - name: app-secrets
    envs:
      - .env.prod                  # each KEY=VALUE line becomes a secret key
    type: kubernetes.io/opaque
    options:
      disableNameSuffixHash: false # default: true = no hash, false = hash appended
```

The generated ConfigMap name becomes `app-config-84f9kbhm2g` (hash of contents). Any Deployment referencing it in `envFrom.configMapRef.name` or `volumes[].configMap.name` gets the reference updated automatically by Kustomize — and because the pod template changed (different ConfigMap name), Kubernetes triggers a rolling restart.

This is the killer feature of generators. With raw `kubectl apply`, updating a ConfigMap silently doesn't restart pods. With Kustomize generators it does, deterministically, with no extra tooling.

Caveats:
1. All consumers of the ConfigMap must be managed by the same Kustomize build. If anything else references the un-hashed name, it breaks.
2. `disableNameSuffixHash: true` gives a stable name but loses the auto-restart behavior. Use it only for ConfigMaps consumed by init containers or mounted as files where the app handles reload itself.

---

## Components

Components (GA in Kustomize 4+) are reusable patches that can be mixed into any overlay without being a base:

```
infra/
  components/
    monitoring/
      kustomization.yaml    # kind: Component
      servicemonitor.yaml
    network-policy/
      kustomization.yaml
      netpol.yaml
  overlays/
    staging/
      kustomization.yaml    # includes monitoring but not network-policy
    prod/
      kustomization.yaml    # includes both
```

```yaml
# components/monitoring/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component

resources:
  - servicemonitor.yaml

patches:
  - target:
      kind: Deployment
    patch: |
      - op: add
        path: /spec/template/metadata/annotations/prometheus.io~1scrape
        value: "true"
      - op: add
        path: /spec/template/metadata/annotations/prometheus.io~1port
        value: "8080"
```

```yaml
# overlays/prod/kustomization.yaml
resources:
  - ../../base

components:
  - ../../components/monitoring
  - ../../components/network-policy
```

Components differ from overlays-as-bases in an important way: a component can patch resources that already exist in the overlay's resource set. It operates as a mutation layer, not an independent resource graph.

---

## Transformers

Transformers mutate all matching objects globally across the entire rendered set.

### namePrefix / nameSuffix

```yaml
namePrefix: prod-
nameSuffix: -v2
```

Kustomize understands cross-references for built-in types: if a Deployment's `volumes[].configMap.name` references a ConfigMap, the prefix/suffix is applied to both the ConfigMap object and the reference in the Deployment. This works for common Kubernetes resources but not for custom CRDs unless you add a `configurations` entry.

### commonLabels and the selector trap

```yaml
commonLabels:
  env: production
  team: platform
```

`commonLabels` adds to `.metadata.labels` **and** all selector fields — `Deployment.spec.selector.matchLabels`, Service selectors, etc. Adding a label to `commonLabels` on a live Deployment causes `kubectl apply` to fail: `selector is immutable after creation`.

Use the safer alternative in Kustomize 4.5+:

```yaml
labels:
  - pairs:
      env: production
      team: platform
    includeSelectors: false   # metadata only, never touches selector fields
    includeTemplates: true    # does update pod template labels
```

### Image transformer

The standard GitOps pattern for image promotion:

```yaml
images:
  - name: myapp                   # matches any container whose image name is myapp
    newName: ghcr.io/org/myapp    # optional: change registry/repo
    newTag: v2.1.0                # pin the tag
  - name: nginx
    newTag: 1.27-alpine
```

The CD pipeline (Argo Image Updater, Flux, or a CI step) updates `newTag` in the overlay's `kustomization.yaml` and commits. The diff is always one line, auditable, and reverts cleanly with a git revert.

Combine with a `newDigest` for immutable builds:

```yaml
images:
  - name: myapp
    newName: ghcr.io/org/myapp
    digest: sha256:4a3b...         # digest beats tag — truly immutable
```

---

## When Kustomize beats Helm

| Situation | Prefer |
|-----------|--------|
| GitOps repo where CD tooling patches image tags per environment | Kustomize — one-line image transformer, auditable diff |
| Upstream chart you can't modify (cert-manager, ingress-nginx) — need to patch one field | Kustomize overlay on the rendered output |
| Multi-team repo where each team owns their overlay | Kustomize — no shared template language to accidentally break |
| Config generation that triggers rolling restarts reliably | Kustomize hash generators |
| Complex app with optional sub-components, external dependencies, lifecycle hooks | Helm |
| Config distributed to others as a versioned artifact | Helm (OCI chart) |
| Enforcing org-wide security defaults across many services | Either — Kustomize components or Helm library chart both work |

They compose: `helm template myrelease ./chart | kubectl apply -k -` and Flux's HelmRelease post-rendering both apply Kustomize on top of Helm output. Pick the right tool at each boundary.

---

## Debugging Kustomize

Kustomize failures are less loud than Helm's — often a patch *silently doesn't apply* and you notice only when prod behaves differently from staging.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Patch applied, but field still shows base value in rendered output | Target selector (kind/name/namespace/labelSelector) doesn't match the object | `kubectl kustomize .` and grep for the object; check `kind` is exactly right (case-sensitive) and `name` matches `metadata.name` in the base |
| `Error: no matches for OriginalId apps_v1_Deployment\|myns/myapp` | Overlay patches an object that doesn't exist in any resource in the DAG | Confirm `resources:` in `kustomization.yaml` includes the file (or base) that defines that object |
| ConfigMap name mismatch after `apply -k` | Referencing the pre-hash name directly; generator appended a hash suffix Kustomize updates cross-refs, but only in resources it manages | Reference the stable pre-hash name — Kustomize auto-updates it. Or add `disableNameSuffixHash: true` |
| `kubectl apply` fails: `Deployment.spec.selector: field is immutable` | `commonLabels` modifies selector fields; can't change on an existing Deployment | Switch to `labels` with `includeSelectors: false`; do a targeted delete-and-recreate |
| JSON 6902 patch hits the wrong container | `/containers/0` index doesn't match expected container after base reorder | Use SMP with `name:` merge key instead; or target by name with a `labelSelector` |
| `namePrefix` applied to objects but CRD cross-references not updated | Kustomize doesn't know the CRD's cross-reference fields | Add a `configurations:` entry mapping the CRD's reference fields to the transformer |

### Diagnose — exact commands

**Patch not applied.**

```bash
# Always render before applying — never guess
kubectl kustomize overlays/prod 2>&1 | grep -A10 "kind: Deployment"

# Side-by-side diff of base vs overlay output
diff <(kubectl kustomize base) <(kubectl kustomize overlays/prod)

# Confirm which patches the overlay declares
grep -A5 "patches:" overlays/prod/kustomization.yaml
```

**Name suffix hash surprises.** Find out what name the generator actually produces:

```bash
kubectl kustomize . | grep "^  name: app-config"
# -> name: app-config-84f9kbhm2g

# Confirm the Deployment's envFrom reference was also updated:
kubectl kustomize . | grep -A5 "envFrom"
# should show: configMapRef: {name: app-config-84f9kbhm2g}
```

**Overlay precedence — which patch wins.** Multiple patches targeting the same field: the last one in the `patches:` array wins for JSON 6902; for SMP, all patches are merged and the last non-nil value for a scalar wins:

```bash
# Render with verbose output to trace patch application order
kubectl kustomize overlays/prod 2>&1
# Then compare: kubectl kustomize overlays/staging vs overlays/prod
# to confirm the winning value comes from the right patch file
```

> **War story.** I was onboarding a new service into our GitOps repo and added `commonLabels: {team: platform}` to the root `kustomization.yaml`. The apply ran fine on dev (fresh namespace). On staging, the Deployment had existed for three months — and `kubectl apply -k` failed immediately with "Deployment.spec.selector: field is immutable." The same overlay had been applied dozens of times before without incident, but this was the first time a label was being added to `commonLabels`. The fix was switching the root kustomization to `labels` with `includeSelectors: false`, then doing a targeted `kubectl delete deploy myapp --wait=false` and re-apply in staging during low-traffic hours. Since then our team policy: `commonLabels` is greenfield-only; any overlay that touches a live cluster uses `labels.includeSelectors: false`. One line of YAML avoided a production incident.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Explain why strategic-merge uses `name` as the merge key for containers, and describe a scenario where this causes the wrong container to be patched.
2. Write a JSON 6902 patch that appends an env var to the first container and removes another by index.
3. Explain what the hash suffix in a generated ConfigMap name achieves, and give the field to disable it.
4. Create a component that adds a `NetworkPolicy` and an annotation to any overlay that includes it.
5. Use the `images` transformer to pin `nginx` to `nginx:1.27-alpine` across all containers in an overlay.
6. Use `labels` with `includeSelectors: false` and explain why it's safer than `commonLabels` on a live cluster.
7. Debug a patch that silently isn't applying using only `kubectl kustomize` and `diff`.
8. Explain how Kustomize handles cross-references when `namePrefix` is set, and where it breaks down.
9. Compose Helm and Kustomize: write the command to apply Kustomize post-rendering on top of a Helm chart.
10. Name one thing Kustomize generators give you that raw `kubectl apply` cannot.

➡ Next: **Operators & CRDs** — extend the Kubernetes API itself with custom resource types and the controllers that act on them.
