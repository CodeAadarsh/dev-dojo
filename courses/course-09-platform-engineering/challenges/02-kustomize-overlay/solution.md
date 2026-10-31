# Solution — Kustomize Overlay for Production

## Build the layout

```bash
mkdir -p /tmp/kustomize-lab/base /tmp/kustomize-lab/overlays/prod
cd /tmp/kustomize-lab
```

### base/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: dojo-kustomize
  labels:
    app: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 64Mi
```

### base/kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
```

### overlays/prod/replica-patch.yaml

A strategic-merge patch. The `apiVersion`, `kind`, `metadata.name`, and `metadata.namespace` are the identity keys that tell Kustomize *which* object to patch. Only `spec.replicas` changes.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: dojo-kustomize
spec:
  replicas: 3
```

### overlays/prod/kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

commonLabels:
  env: prod

patches:
  - path: replica-patch.yaml
```

`commonLabels` stamps `env: prod` onto every resource's `metadata.labels` *and* onto the pod template's `metadata.labels`. That's why the Deployment and its pods both carry the label.

## Apply

```bash
# Dry-run first — see exactly what will be sent
kubectl diff -k overlays/prod/

# Apply for real
kubectl apply -k overlays/prod/

# Watch the rollout
kubectl -n dojo-kustomize rollout status deploy/web

# Verify
bash courses/course-09-platform-engineering/challenges/02-kustomize-overlay/verify.sh
```

## Why each piece matters

- **Strategic-merge patch** understands Kubernetes object structure. Setting `spec.replicas: 3` in the patch replaces that one field; it does not replace the whole `spec`. A JSON6902 patch would need explicit path syntax (`/spec/replicas`) — more precise but more verbose. Use strategic-merge for simple field overrides.
- **`commonLabels`** is a Kustomize shorthand that adds a label to every resource and to pod `spec.template.metadata.labels`. The downside: it also tries to add the label to `selector.matchLabels`, which is immutable on an existing Deployment. If you're updating an already-deployed Deployment, Kustomize will error on the selector change. The correct approach for existing clusters is `labels:` (which skips selectors) instead of `commonLabels:`. For this challenge the namespace is fresh, so `commonLabels` works fine.
- **`kubectl diff -k`** is the Kustomize equivalent of `terraform plan` — always run it before `apply` in production. It shows the server-side diff so you see what is actually changing, not just what you think is changing.

## Attacker's view

From a security posture, Kustomize bases are often shared across teams in a monorepo. A malicious or accidental change to the base propagates to every overlay on the next `kubectl apply -k`. Pin your base reference to a git SHA if you're consuming a shared base you don't own:

```yaml
# overlays/prod/kustomization.yaml
resources:
  - github.com/myorg/k8s-bases/apps/web?ref=abc1234
```
