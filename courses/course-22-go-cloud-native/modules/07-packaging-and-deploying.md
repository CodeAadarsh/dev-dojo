# Packaging & Deploying the Operator

> **Module 07 · Course 22** — A reconciler that only runs via `make run` on your laptop is a script. This module packages the controller into a minimal, secure container image, writes the RBAC manifests it needs to function, and gets it running inside the kind cluster. Then it wraps everything in Kustomize and a Helm chart so you can hand it to a team, not just a machine.

---

## The Dockerfile — slim, static, non-root

The default `golang:1.22` build image is ~900 MB. The goal is a final image under 25 MB. The path there is three decisions: disable CGO for a static binary, use `gcr.io/distroless/static:nonroot` as the final base, and never run as root.

```dockerfile
# --- build stage ---
FROM golang:1.22-alpine AS builder

WORKDIR /workspace

# download deps as a separate layer — only invalidated when go.mod/go.sum change
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# CGO_ENABLED=0  → static binary, no glibc dependency
# -trimpath      → removes local build paths from debug info (no /home/user/... in the binary)
# -ldflags -s -w → strip symbol table and DWARF, shaves ~30% off binary size
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" \
    -o manager cmd/main.go

# --- final stage ---
FROM gcr.io/distroless/static-debian12:nonroot

WORKDIR /

COPY --from=builder /workspace/manager .

# distroless/static-debian12:nonroot sets uid 65532 ("nonroot") as the image default.
# Explicitly declaring it makes the non-root intent auditable in the Dockerfile.
USER 65532:65532

ENTRYPOINT ["/manager"]
```

Why each decision:

| Decision | Reason |
|----------|--------|
| `golang:1.22-alpine` build stage | Full toolchain; `-alpine` trims 300 MB vs the default Debian image |
| `distroless/static-debian12:nonroot` final | No shell, no `apt`, no `/etc/passwd` entries for common accounts — attack surface is the binary and nothing else |
| `USER 65532:65532` | Kubernetes Pod Security Standards (Restricted profile) reject containers running as root; `runAsNonRoot: true` in the pod spec will block a root container at admission |
| `CGO_ENABLED=0` | Produces a fully static binary; distroless/static has no `ld-linux`, so CGO-linked binaries crash at runtime with `no such file or directory` |
| `-trimpath` | Removes the absolute build paths from the binary — no `/Users/dev/widget-operator/` strings in the shipped artifact |
| `COPY go.mod go.sum ./` first | Docker layer cache: the deps layer is only rebuilt when the module graph changes, not on every source edit |

### Multi-arch builds

Your Mac Mini M2 runs ARM64. A default `docker build` produces an `arm64` image. Your production cluster likely runs `amd64`. Build for both:

```bash
# create a multi-platform builder if you haven't already
docker buildx create --use --name multi

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t myrepo/widget-operator:v1.0.0 \
  --push .
```

For the local kind cluster on an M2 Mac, target `linux/arm64`. Getting this wrong produces an `Exec format error` in the pod's `describe` — the kubelet successfully pulled the image but the kernel refused to execute it because the ELF header declares the wrong architecture. See the Debugging section for the exact diagnostic.

---

## RBAC manifests

Kubebuilder generates RBAC manifests from `// +kubebuilder:rbac` markers in the controller file. The markers are the authoritative source — never hand-edit `config/rbac/role.yaml` and then edit the markers too or they'll drift.

Add these above the `Reconcile` function:

```go
// +kubebuilder:rbac:groups=apps.dojo.io,resources=widgets,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=apps.dojo.io,resources=widgets/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=apps.dojo.io,resources=widgets/finalizers,verbs=update
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=configmaps;events,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=coordination.k8s.io,resources=leases,verbs=get;list;watch;create;update;patch;delete
func (r *WidgetReconciler) Reconcile(...) ...
```

Regenerate:

```bash
make manifests
```

Inspect the generated `config/rbac/role.yaml` before applying — `make manifests` generates minimum-required rules from your markers, but if you used a broad tutorial example as your starting point, you might have inherited a `verbs: ["*"]` wildcard. Grep for it and narrow it down:

```bash
grep 'verbs' config/rbac/role.yaml
```

The `leases` rule is for leader election — the controller acquires a Lease object in `kube-system` (or the operator namespace) to ensure only one replica acts as the active reconciler. Missing that rule causes the leader election loop to spam 403 errors at startup and the controller to refuse to start.

---

## The manager Deployment

```yaml
# config/manager/manager.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: widget-controller-manager
  namespace: dojo-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: widget-controller-manager
  template:
    metadata:
      labels:
        app: widget-controller-manager
    spec:
      serviceAccountName: widget-controller-manager
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      terminationGracePeriodSeconds: 10
      containers:
      - name: manager
        image: myrepo/widget-operator:v1.0.0   # never :latest
        args:
        - --leader-elect
        - --metrics-bind-address=:8443
        - --health-probe-bind-address=:8081
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8081
          initialDelaySeconds: 15
          periodSeconds: 20
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8081
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          limits:
            cpu: 500m
            memory: 128Mi
          requests:
            cpu: 10m
            memory: 64Mi
```

The `/healthz` and `/readyz` endpoints are wired automatically by controller-runtime's manager when you pass `--health-probe-bind-address`. Register health checks in `cmd/main.go`:

```go
if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
    setupLog.Error(err, "unable to set up health check")
    os.Exit(1)
}
if err := mgr.AddReadyzCheck("readyz", mgr.GetWebhookServer().StartedChecker()); err != nil {
    setupLog.Error(err, "unable to set up ready check")
    os.Exit(1)
}
```

`healthz.Ping` is always true — it means the process is alive. `StartedChecker` gates readiness on the webhook server being up (if you have admission webhooks). For an operator without webhooks, replace `StartedChecker` with `healthz.Ping` for readyz too, or implement a custom check that verifies your operator's informer caches are synced.

---

## Build, load, deploy — the kind workflow

```bash
# 1. Build the image for the kind cluster's architecture (ARM64 on an M2 Mac)
docker build --platform linux/arm64 -t widget-operator:dev .

# 2. Load into every node in the dojo cluster
#    The cluster does NOT pull from your local Docker daemon — this copy step is required.
kind load docker-image widget-operator:dev --name dojo

# 3. Create the namespace
kubectl create namespace dojo-operator --dry-run=client -o yaml | kubectl apply -f -

# 4. Apply CRDs first — the controller will fail to start if the Widget CRD doesn't exist
kubectl apply -f config/crd/bases/

# 5. Apply RBAC
kubectl apply -f config/rbac/

# 6. Apply the manager Deployment (ensure the image field matches :dev)
kubectl apply -f config/manager/

# 7. Watch the rollout
kubectl -n dojo-operator rollout status deploy/widget-controller-manager

# 8. Smoke test
kubectl apply -f - <<EOF
apiVersion: apps.dojo.io/v1
kind: Widget
metadata:
  name: smoke-widget
  namespace: default
spec:
  replicas: 2
  image: nginx:1.27-alpine
EOF

kubectl get widget smoke-widget -w
kubectl -n dojo-operator logs deploy/widget-controller-manager -f
```

Inner dev loop after any code change:

```bash
docker build --platform linux/arm64 -t widget-operator:dev . && \
kind load docker-image widget-operator:dev --name dojo && \
kubectl -n dojo-operator rollout restart deploy/widget-controller-manager
```

This forces a new pod with the new image. Because the tag `:dev` doesn't change, set `imagePullPolicy: IfNotPresent` (or `Never`) in the Deployment — otherwise the kubelet tries to pull from a registry where `:dev` doesn't exist.

---

## Kustomize packaging

The `config/` tree is already a Kustomize project. Use overlays for per-environment customisation instead of maintaining separate YAML copies:

```
config/
├── default/
│   └── kustomization.yaml    # patches together crd/ + rbac/ + manager/
└── overlays/
    ├── dev/
    │   └── kustomization.yaml  # image tag :dev, imagePullPolicy Never
    └── prod/
        └── kustomization.yaml  # image tag pinned, resource limits tuned
```

`config/overlays/dev/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../default

images:
- name: myrepo/widget-operator
  newTag: dev

patches:
- patch: |-
    - op: replace
      path: /spec/template/spec/containers/0/imagePullPolicy
      value: IfNotPresent
  target:
    kind: Deployment
    name: widget-controller-manager
```

Deploy the dev overlay:

```bash
kubectl apply -k config/overlays/dev/
```

Preview what it would render without applying:

```bash
kubectl kustomize config/overlays/dev/
```

### Helm chart (alternative)

For teams standardised on Helm, scaffold a chart and move the generated manifests into `templates/`:

```
widget-operator/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── crd.yaml
    ├── serviceaccount.yaml
    ├── clusterrole.yaml
    ├── clusterrolebinding.yaml
    └── deployment.yaml
```

`values.yaml`:

```yaml
image:
  repository: myrepo/widget-operator
  tag: v1.0.0
  pullPolicy: IfNotPresent
replicaCount: 1
leaderElect: true
resources:
  requests:
    cpu: 10m
    memory: 64Mi
  limits:
    cpu: 500m
    memory: 128Mi
```

```bash
helm install widget-operator ./widget-operator -n dojo-operator --create-namespace
helm upgrade widget-operator ./widget-operator -n dojo-operator --set image.tag=v1.1.0
```

> **CRDs in Helm.** Helm has a `crds/` directory for CRD templates — they're applied before all other templates and are intentionally not deleted on `helm uninstall` (to avoid losing live CustomResource data). The downside: schema upgrades require `kubectl replace` or `--force` because Helm won't update CRDs on `helm upgrade` by default. Many teams prefer Kustomize for the CRD lifecycle and Helm for the controller Deployment.

---

## Metrics and health endpoints

controller-runtime exposes a Prometheus metrics endpoint at `:8443/metrics` by default. Add domain-specific metrics with the controller-runtime registry:

```go
import (
    "sigs.k8s.io/controller-runtime/pkg/metrics"
    "github.com/prometheus/client_golang/prometheus"
)

var (
    widgetsReconciled = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "widget_reconcile_total",
            Help: "Number of Widget reconcile loops completed.",
        },
        []string{"result"}, // labels: "success" | "error"
    )
    widgetReadyGauge = prometheus.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "widget_ready_replicas",
            Help: "Current ready replicas per Widget.",
        },
        []string{"name", "namespace"},
    )
)

func init() {
    metrics.Registry.MustRegister(widgetsReconciled, widgetReadyGauge)
}

// in Reconcile on success:
widgetsReconciled.WithLabelValues("success").Inc()
widgetReadyGauge.WithLabelValues(widget.Name, widget.Namespace).Set(
    float64(widget.Status.ReadyReplicas))

// on error:
widgetsReconciled.WithLabelValues("error").Inc()
```

Verify the metrics endpoint locally:

```bash
kubectl -n dojo-operator port-forward svc/widget-controller-manager-metrics-service 8443:8443 &
# controller-runtime's default metrics are TLS-protected; skip cert verification for local checks
curl -sk https://localhost:8443/metrics | grep widget_reconcile
```

---

## Debugging Deployment

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `CrashLoopBackOff`; logs: `failed to get API group resources: ... 403 Forbidden` | ServiceAccount is missing RBAC permissions for a resource the controller tries to list or watch at startup | Read the 403 — it names the resource and verb; add the missing rule to `role.yaml`, re-run `make manifests`, re-apply RBAC |
| Pod stays `Pending` or starts then exits with `Exec format error` in `kubectl describe` events | Image built for the wrong CPU architecture | Rebuild with the correct `--platform` flag; re-load with `kind load docker-image` |
| Controller exits immediately: `error waiting for cache sync` | CRD not applied before the Deployment was created; informer for Widget has no registered type | Apply CRDs first: `kubectl apply -f config/crd/bases/`; restart the manager Deployment |
| Leader election log spam: `failed to acquire leader lease`, `context deadline exceeded` | ServiceAccount missing `get/update` on `leases` in `coordination.k8s.io`, or the lease namespace is wrong | `kubectl auth can-i update leases.coordination.k8s.io --as=system:serviceaccount:dojo-operator:widget-controller-manager -n dojo-operator`; add the missing RBAC rule |
| Rolling restart never completes — old pod stays `Terminating` | Long reconcile loop not respecting `ctx.Done()`, or `terminationGracePeriodSeconds` is too generous | Check that every blocking call inside `Reconcile` passes the context; add `ctx.Done()` checks in long-running loops; reduce `terminationGracePeriodSeconds` |
| Deployment created but `kubectl get widget -o yaml` shows empty status | Status subresource RBAC missing — controller can't write to `/widgets/status` | Add `verbs: [get, update, patch]` for `widgets/status` in `role.yaml`; test with `kubectl auth can-i update widgets/status --as=...` |

> **War story.** I deployed an operator to a new production cluster and the controller entered CrashLoopBackOff within 30 seconds. The log line was `cannot list resource "deployments" in API group "apps" in the namespace "production": ... User "system:serviceaccount:operators:widget-controller-manager" cannot list`. The ClusterRole was correct — we'd verified it in staging. The bug was in the ClusterRoleBinding: the `subjects[].namespace` field said `default` instead of `operators`. A RoleBinding with the wrong subject namespace silently matches zero service accounts; it creates no error at apply time, and the cluster happily runs with a binding that never fires. The fix was two lines in the RoleBinding YAML. The lesson: `kubectl auth can-i list deployments --as=system:serviceaccount:<namespace>:<serviceaccount>` evaluates the actual policy, not what you think you configured. Make it the first command you run when an operator says 403.

---

## Checkpoint

You're ready for the packaging challenges when you can, without looking it up:

1. Write a two-stage Dockerfile for a Go operator that produces a non-root image under 25 MB with a static binary.
2. State the three `go build` flags that produce a stripped static binary and explain what each does.
3. Explain the difference between `USER 65532:65532` in a Dockerfile and `runAsNonRoot: true` in the pod spec — when does each one enforce non-root?
4. List the `+kubebuilder:rbac` markers needed for a controller that manages Deployments, writes ConfigMaps, emits Events, and runs with leader election.
5. Run `kubectl auth can-i` to verify that the controller's ServiceAccount can update Widget status — write the exact command.
6. Explain why `kind load docker-image` is necessary and what happens if you skip it.
7. Explain when to put CRDs in Helm's `crds/` directory vs `templates/`, and why Helm doesn't delete them on `helm uninstall`.
8. Diagnose a `CrashLoopBackOff` where the controller log shows a 403 — list the two commands you run and the file you edit to fix it.

➡ Next up: the **operator challenges** — scaffold, wire, and deploy a working Widget operator on a live kind cluster, then prove it with a verifier.
