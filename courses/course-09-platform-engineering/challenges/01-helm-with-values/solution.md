# Solution — Helm Chart with Values Override

## Step 1 — scaffold the chart

```bash
mkdir -p /tmp/helm-lab && cd /tmp/helm-lab
helm create portal-app
```

`helm create` drops a full scaffold: `Chart.yaml`, `values.yaml`, `templates/` with Deployment, Service, HPA, ServiceAccount, and Ingress stubs. The two pieces to understand are:

- **`values.yaml`** — the user-facing knobs. Everything rendered in `templates/` substitutes from here.
- **`templates/_helpers.tpl`** — the `fullname` helper. When the release name (`portal`) doesn't contain the chart name (`portal-app`), fullname is `portal-portal-app`. When it does, fullname is just the release name.

```bash
# preview what will be installed before touching the cluster
helm install portal ./portal-app -n dojo-helm2 \
  --set replicaCount=2 \
  --set image.repository=nginx \
  --set image.tag=1.27-alpine \
  --dry-run
```

The dry-run output shows the rendered manifests. Read the Deployment; confirm `spec.replicas: 2` and `image: nginx:1.27-alpine`.

## Step 2 — install

```bash
helm install portal ./portal-app \
  -n dojo-helm2 \
  --set replicaCount=2 \
  --set image.repository=nginx \
  --set image.tag=1.27-alpine
```

Alternatively, write a values file (preferred for anything beyond one or two overrides):

```yaml
# my-values.yaml
replicaCount: 2
image:
  repository: nginx
  tag: 1.27-alpine
  pullPolicy: IfNotPresent
```

```bash
helm install portal ./portal-app -n dojo-helm2 -f my-values.yaml
```

## Step 3 — verify

```bash
helm -n dojo-helm2 list
kubectl -n dojo-helm2 get deploy,pods
bash courses/course-09-platform-engineering/challenges/01-helm-with-values/verify.sh
```

## Why each piece matters

- **`helm create` scaffold** ships with opinionated defaults: rolling update strategy, liveness/readiness probes (commented), HPA, service account, and proper `app.kubernetes.io/*` labels (the new standard, not the deprecated `app:` label). These are production-ready defaults — don't strip them.
- **Values override at install time** is the core Helm value proposition. The same chart ships to dev, staging, and prod by changing only the values: `image.tag`, `replicaCount`, `ingress.host`. The `--set` flag is for CI/one-offs; `-f values.yaml` is for committed per-env configuration.
- **`helm list`** is your release ledger. Helm tracks revision history in the kube-system namespace as Secrets — `helm history portal -n dojo-helm2` shows every upgrade. `helm rollback portal 1 -n dojo-helm2` reverts to any prior revision. This is why "we deployed via helm" is auditable in a way that `kubectl apply` alone is not.

## Upgrade path (preview)

```bash
# Bump replica count without touching the chart
helm upgrade portal ./portal-app -n dojo-helm2 \
  --set replicaCount=3 \
  --set image.repository=nginx \
  --set image.tag=1.27-alpine \
  --reuse-values    # merges new --set flags over the installed values
```

`--reuse-values` is convenient but subtle: it reuses the last release's computed values, which can include values set by a CI step you no longer control. Prefer explicit `-f` files in production.
