# Building an Operator with Kubebuilder

> **Module 05 · Course 22** — A Deployment gives you "N replicas of this pod." A StatefulSet gives you ordered, stable-identity pods with PVCs. When neither pattern fits your domain object — a database cluster, a certificate lifecycle, a tenant provisioning workflow — you write an Operator: a controller that watches a custom resource and drives the world toward whatever that resource declares. Kubebuilder turns the blank-page problem into generated scaffolding where you fill in the logic.

You already know the conceptual reconcile loop. This module puts it under a microscope and leaves you with a working Widget operator by the end.

---

## The landscape

Before using Kubebuilder, know what you're actually using:

```
Kubebuilder CLI
    └── generates scaffolding that imports...
controller-runtime (sigs.k8s.io/controller-runtime)
    └── wraps client-go informers + workqueues behind a sane API
        └── client-go
            └── talks to the Kubernetes API server
```

Operator SDK wraps Kubebuilder and adds Ansible/Helm operator modes. For pure Go operators, reaching for Kubebuilder directly keeps the generated code explicit and readable. Once it's on disk there is no magic — it's plain Go you can step through in a debugger.

---

## Scaffolding

```bash
# install the CLI (pin to a specific version)
go install sigs.k8s.io/kubebuilder/cmd/kubebuilder@v3.14.0

# bootstrap the operator module
mkdir widget-operator && cd widget-operator
kubebuilder init --domain dojo.io --repo github.com/dojo/widget-operator

# scaffold the API type + controller stub
kubebuilder create api --group apps --version v1 --kind Widget
# at both prompts answer y (Create Resource, Create Controller)
```

What `kubebuilder init` lays down:

```
widget-operator/
├── cmd/main.go              # registers controllers, starts the manager
├── config/                  # Kustomize bases — CRDs, RBAC, manager Deployment
│   ├── crd/
│   ├── rbac/
│   └── manager/
├── go.mod
└── Makefile
```

After `create api`:

```
api/v1/
├── widget_types.go          # CRD struct — you edit this
├── groupversion_info.go     # group/version constants
└── zz_generated.deepcopy.go # generated — never edit by hand

internal/controller/
└── widget_controller.go     # Reconcile() stub — you edit this
```

The Makefile targets you'll use constantly:

```bash
make generate    # regenerates zz_generated.deepcopy.go from your types
make manifests   # regenerates CRD YAML in config/crd/ from +kubebuilder markers
make run         # runs the controller out-of-cluster against ~/.kube/config
```

> **Run `make generate && make manifests` after every struct change.** Forgetting this is the single most common reason "my CRD change has no effect" — the YAML in `config/crd/` is stale, the cluster is validating against the old schema, and your reconciler is reading a type that doesn't match the applied CRD. Never commit a struct change without regenerating.

---

## The Widget type — spec, status, markers

Open `api/v1/widget_types.go`. Replace the placeholder structs:

```go
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Replicas",type="integer",JSONPath=".spec.replicas"
// +kubebuilder:printcolumn:name="Ready",type="integer",JSONPath=".status.readyReplicas"
// +kubebuilder:printcolumn:name="Age",type="date",JSONPath=".metadata.creationTimestamp"

// Widget manages a Deployment and a ConfigMap, keeping them in sync with its spec.
type Widget struct {
    metav1.TypeMeta   `json:",inline"`
    metav1.ObjectMeta `json:"metadata,omitempty"`

    Spec   WidgetSpec   `json:"spec,omitempty"`
    Status WidgetStatus `json:"status,omitempty"`
}

type WidgetSpec struct {
    // +kubebuilder:validation:Minimum=1
    // +kubebuilder:validation:Maximum=10
    // +kubebuilder:default=1
    Replicas int32 `json:"replicas"`

    // +kubebuilder:validation:Pattern=`^[a-zA-Z0-9][a-zA-Z0-9._\-/:@]*$`
    Image string `json:"image"`

    // +optional
    ConfigData map[string]string `json:"configData,omitempty"`
}

type WidgetStatus struct {
    ReadyReplicas int32              `json:"readyReplicas,omitempty"`
    Conditions    []metav1.Condition `json:"conditions,omitempty" patchStrategy:"merge" patchMergeKey:"type"`
}

// +kubebuilder:object:root=true
type WidgetList struct {
    metav1.TypeMeta `json:",inline"`
    metav1.ListMeta `json:"metadata,omitempty"`
    Items           []Widget `json:"items"`
}
```

Key marker semantics:

| Marker | What it does |
|--------|-------------|
| `+kubebuilder:object:root=true` | Registers this as a root API type (has its own endpoint, not embedded) |
| `+kubebuilder:subresource:status` | Adds a `/status` subresource — status writes go through a separate path, preventing spec/status merge conflicts under concurrent updates |
| `+kubebuilder:validation:Minimum=1` | Injects CEL/OpenAPI validation into the generated CRD schema; the API server rejects invalid values before your controller ever sees the object |
| `+kubebuilder:default=1` | Sets the field default if omitted at creation time; encoded in the CRD schema, not in your Go code |
| `+kubebuilder:printcolumn` | Adds extra columns to `kubectl get widgets` — your server-side columns, always consistent across machines |

After any struct edit:

```bash
make generate && make manifests
kubectl apply -f config/crd/bases/
```

---

## The reconcile loop in depth

`internal/controller/widget_controller.go` receives a `Reconcile(ctx, req)` call whenever a Widget changes, or whenever a resource owned by a Widget changes (because you wired up `Owns()` in `SetupWithManager`). The function must be idempotent — it may be called many times for the same state.

```go
const widgetFinalizer = "apps.dojo.io/finalizer"

func (r *WidgetReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log := log.FromContext(ctx)

    // 1. Fetch the Widget. IgnoreNotFound handles deletion races gracefully.
    widget := &appsv1.Widget{}
    if err := r.Get(ctx, req.NamespacedName, widget); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // 2. Deletion path — handle cleanup before the object is gone.
    if !widget.DeletionTimestamp.IsZero() {
        return r.handleDeletion(ctx, widget)
    }

    // 3. Ensure finalizer is registered while the object is alive.
    if !controllerutil.ContainsFinalizer(widget, widgetFinalizer) {
        controllerutil.AddFinalizer(widget, widgetFinalizer)
        return ctrl.Result{}, r.Update(ctx, widget)
        // return immediately — the Update triggers a new reconcile with the finalizer present
    }

    // 4. Reconcile child resources.
    if err := r.reconcileConfigMap(ctx, widget); err != nil {
        return ctrl.Result{}, err
    }
    if err := r.reconcileDeployment(ctx, widget); err != nil {
        return ctrl.Result{}, err
    }

    // 5. Update status from observed child state.
    if err := r.updateStatus(ctx, widget); err != nil {
        return ctrl.Result{}, err
    }

    log.Info("reconciled", "widget", req.NamespacedName)
    return ctrl.Result{}, nil
}
```

### Ownership and garbage collection

When your controller creates a child resource, set the owner reference so deleting the Widget cascades automatically:

```go
func (r *WidgetReconciler) reconcileDeployment(ctx context.Context, w *appsv1.Widget) error {
    deploy := &k8sappsv1.Deployment{
        ObjectMeta: metav1.ObjectMeta{
            Name:      w.Name,
            Namespace: w.Namespace,
        },
    }
    _, err := controllerutil.CreateOrUpdate(ctx, r.Client, deploy, func() error {
        // SetControllerReference adds ownerReferences — cascading delete is free.
        if err := controllerutil.SetControllerReference(w, deploy, r.Scheme); err != nil {
            return err
        }
        deploy.Spec = buildDeploymentSpec(w)
        return nil
    })
    return err
}
```

`controllerutil.CreateOrUpdate` does an atomic get-then-create-or-patch. Calling it on every reconcile pass is safe — if nothing changed, the patch is a no-op and no write goes to the API server.

### ctrl.Result return semantics

| Return | Behaviour |
|--------|-----------|
| `ctrl.Result{}`, `nil` | Success — wait for the next watch event |
| `ctrl.Result{RequeueAfter: 30 * time.Second}`, `nil` | Requeue in 30 s — right for polling external systems with no watch |
| `ctrl.Result{}`, `err` | Failure — exponential-backoff retry via the work queue |
| `ctrl.Result{Requeue: true}`, `nil` | Immediate requeue — avoid this in success paths; it creates a hot loop |

Returning an error is the standard retry path. Return `RequeueAfter` when you're waiting on something that won't generate a watch event (a cloud API, a DNS record, a certificate becoming valid).

### Wiring watches in SetupWithManager

```go
func (r *WidgetReconciler) SetupWithManager(mgr ctrl.Manager) error {
    return ctrl.NewControllerManagedBy(mgr).
        For(&appsv1.Widget{}).
        Owns(&k8sappsv1.Deployment{}).  // enqueue Widget when its owned Deployment changes
        Owns(&corev1.ConfigMap{}).
        Complete(r)
}
```

`Owns()` tells controller-runtime: "if this child changes, look up its ownerReference and enqueue the parent Widget." Without it, a manual deletion of a child Deployment wouldn't trigger a reconcile to recreate it.

---

## Status updates and conditions

Use `metav1.Condition` (from `k8s.io/apimachinery/pkg/apis/meta/v1`) rather than a raw string field. It gives `kubectl wait --for=condition=Ready` for free and produces a standardised structure that tooling can reason about.

```go
const (
    TypeReady        = "Ready"
    ReasonReconciled = "Reconciled"
    ReasonDegraded   = "Degraded"
)

func (r *WidgetReconciler) updateStatus(ctx context.Context, w *appsv1.Widget) error {
    deploy := &k8sappsv1.Deployment{}
    if err := r.Get(ctx, types.NamespacedName{Name: w.Name, Namespace: w.Namespace}, deploy); err != nil {
        return err
    }

    ready := deploy.Status.ReadyReplicas >= w.Spec.Replicas
    condStatus := metav1.ConditionTrue
    reason, msg := ReasonReconciled, fmt.Sprintf("%d/%d replicas ready", deploy.Status.ReadyReplicas, w.Spec.Replicas)
    if !ready {
        condStatus = metav1.ConditionFalse
        reason = ReasonDegraded
    }

    meta.SetStatusCondition(&w.Status.Conditions, metav1.Condition{
        Type:               TypeReady,
        Status:             condStatus,
        Reason:             reason,
        Message:            msg,
        ObservedGeneration: w.Generation,
    })
    w.Status.ReadyReplicas = deploy.Status.ReadyReplicas

    // MUST use r.Status().Update() — NOT r.Update()
    return r.Status().Update(ctx, w)
}
```

`r.Status().Update()` vs `r.Update()` is not a style choice. The API server routes status writes through a separate `/status` endpoint that only the `+kubebuilder:subresource:status` marker enables. If you call `r.Update()` on an object with a modified status, the API server silently drops the status fields — the spec change (if any) goes through but status is reset to whatever the server had. This is one of the hardest bugs to notice because there is no error returned.

---

## Finalizers

A finalizer is a string in `metadata.finalizers`. The API server refuses to actually delete an object that has finalizers — it sets `deletionTimestamp` and waits for a controller to do cleanup and then remove the string.

```go
func (r *WidgetReconciler) handleDeletion(ctx context.Context, w *appsv1.Widget) (ctrl.Result, error) {
    if controllerutil.ContainsFinalizer(w, widgetFinalizer) {
        // cleanup external resources — must be idempotent (may be called multiple times on error)
        if err := r.cleanupExternalResources(ctx, w); err != nil {
            return ctrl.Result{}, err
        }
        controllerutil.RemoveFinalizer(w, widgetFinalizer)
        if err := r.Update(ctx, w); err != nil {
            return ctrl.Result{}, err
        }
    }
    // with no finalizers left, the API server proceeds with the actual delete
    return ctrl.Result{}, nil
}
```

Two rules that prevent finalizer deadlocks:

1. Make `cleanupExternalResources` idempotent — a transient error will cause a retry, and that retry must not fail because the resource was partially cleaned on the previous attempt.
2. Log what the cleanup attempted *before* returning an error. If the cleanup logic itself has a bug and panics or loops, you need enough signal in the logs to reconstruct the external state manually.

---

## Events

Events surface in `kubectl describe widget my-widget` under `Events:`. They're light-weight audit entries tied to a specific object.

```go
// in SetupWithManager, add the recorder:
r.Recorder = mgr.GetEventRecorderFor("widget-controller")

// in Reconcile — normal operations:
r.Recorder.Event(widget, corev1.EventTypeNormal, "Reconciled", "Deployment synced to desired state")

// warning — something an on-call person should notice:
r.Recorder.Eventf(widget, corev1.EventTypeWarning, "DegradedReplicas",
    "only %d/%d replicas ready", widget.Status.ReadyReplicas, widget.Spec.Replicas)
```

Emit events on state transitions, not on every reconcile pass of a healthy object. The API server rate-limits event creation per object — flooding it buries real warnings and makes `kubectl describe` useless to read.

---

## Debugging Kubebuilder

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `kubectl get widgets` → `no matches for kind "Widget"` | CRD not applied, or `make manifests` not re-run after a struct change | `make manifests && kubectl apply -f config/crd/bases/` |
| Status is always empty on `kubectl get widget -o yaml` | Missing `+kubebuilder:subresource:status` marker, or reconciler calls `r.Update()` instead of `r.Status().Update()` | Add the marker, re-run `make manifests`, re-apply the CRD; switch the status write to `r.Status().Update()` |
| Widget stuck in `Terminating` permanently | Finalizer not removed — `cleanupExternalResources` is returning an error on every retry | Fix the cleanup to be idempotent; if the external resource is confirmed gone, force-remove: `kubectl patch widget <name> -p '{"metadata":{"finalizers":[]}}' --type=merge` |
| `r.Get()` returns stale data immediately after `r.Update()` | controller-runtime uses a local informer cache; the write hasn't been ingested yet | Either restructure so you don't need to re-read immediately, or use `r.APIReader.Get()` (bypasses cache) for that one read |
| `resource version conflict` logged on every reconcile | Two code paths updating the same object simultaneously, or returning `Requeue: true` after a successful update | Ensure only one update path runs per reconcile call; never return `Requeue: true` alongside a successful `Update` |
| `make run` succeeds but changes to the Widget spec have no effect | Stale CRD schema in the cluster — `config/crd/bases/` YAML not re-applied after `make manifests` | `kubectl apply -f config/crd/bases/` to patch the live CRD schema |

> **War story.** We deployed an operator that registered a finalizer on every object in a namespace, but the cleanup function called an internal HTTP API that was unreachable from the cluster network — a firewall rule nobody had documented. Every object entered `Terminating` and stayed there. The namespace itself couldn't be deleted because the API server refuses namespace deletion until all resources inside are gone. We couldn't simply redeploy the operator with the firewall fix because the CRD delete also blocked on the stuck objects. The recovery was two-step: first deploy the fixed operator (which could actually reach the HTTP API) and let it drain the finalizers naturally, then proceed with the deletion. After that incident we added a `context.WithTimeout(ctx, 5*time.Second)` around every external call inside a finalizer handler — if the call times out, we log what we attempted and return the error to trigger a retry rather than blocking indefinitely. A finalizer that can block forever is a production time bomb.

---

## Checkpoint

You're ready for the operator challenges when you can, without looking it up:

1. Explain the difference between `make generate` and `make manifests`, and name a concrete situation where running only one of them leads to a subtle bug.
2. Write a `WidgetSpec` field that accepts integers from 1 to 20 with a default of 3, using `+kubebuilder` markers.
3. State why `r.Status().Update()` is required (not `r.Update()`) when writing the status subresource, and describe the failure mode when you use the wrong call.
4. Implement a `reconcileConfigMap` that uses `controllerutil.CreateOrUpdate` and sets an owner reference.
5. Describe the full lifecycle of a finalizer: how it gets added, what the API server does when `kubectl delete` is called, and the exact steps to remove it.
6. Explain what `ctrl.Result{RequeueAfter: 30 * time.Second}` does and give one case where it's the correct return value rather than returning an error.
7. Diagnose a Widget stuck in `Terminating` — which `kubectl` command tells you why, and what is the force-recovery patch?
8. Emit a `Warning` event tied to a Widget resource and identify exactly where that event appears when you run `kubectl describe`.

➡ Next up: **Testing Go & Controllers** — table-driven unit tests, the fake client, and envtest for a real API server in your test binary.
