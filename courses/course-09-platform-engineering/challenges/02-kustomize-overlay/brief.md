# Kustomize Overlay for Production

Your team manages the same service across dev, staging, and prod. Helm was vetoed ("too much templating magic"). The alternative: **Kustomize** — plain YAML at the base, per-environment overlays that patch only what changes. No templating language, no chart to maintain, just strategic-merge and JSON6902 patches applied by `kubectl apply -k`.

The catch: Kustomize's patching model is deliberately minimal and breaks in non-obvious ways when you get the patch type wrong. This challenge makes you touch both the happy path and the structure.

## Directory layout to build

Build this outside the kube-dojo tree (e.g. `/tmp/kustomize-lab/`):

```
.
├── base/
│   ├── kustomization.yaml
│   └── deployment.yaml
└── overlays/
    └── prod/
        ├── kustomization.yaml
        └── replica-patch.yaml
```

## Base requirements

`base/deployment.yaml` — a Deployment named **`web`** in namespace `dojo-kustomize` running `nginx:1.27-alpine` with 1 replica.

`base/kustomization.yaml` — declares `deployment.yaml` as a resource.

## Prod overlay requirements

`overlays/prod/kustomization.yaml` — references `../../base` and applies `replica-patch.yaml` as a patch. It must also add label **`env: prod`** to all resources via `commonLabels`.

`overlays/prod/replica-patch.yaml` — a strategic-merge patch that sets `spec.replicas: 3` for Deployment `web`.

## Apply

```bash
kubectl apply -k overlays/prod/
```

The verifier checks (in namespace `dojo-kustomize`):

- Deployment `web` exists.
- `spec.replicas` is **3**.
- The Deployment has label **`env: prod`**.
- At least 3 pods are Ready.

Run the verifier:

```bash
bash courses/course-09-platform-engineering/challenges/02-kustomize-overlay/verify.sh
```

## Why this matters

Kustomize ships inside `kubectl` — no binary to install, no dependency to pin, no chart registry. Every GitOps tool (Flux, Argo CD) understands it natively. The overlay pattern lets a single base track across environments with auditable diffs: `kubectl diff -k overlays/prod/` shows exactly what would change. That's the kind of paper trail a platform team lives by.
