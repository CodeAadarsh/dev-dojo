# client-go & controller-runtime

> **Module 04 · Course 22** — The Kubernetes API is a declarative state machine, and Go is its native language. `client-go` is the library that speaks to the API server; `controller-runtime` wraps it into a reconcile loop. By the end of this module you will understand the reconcile model deeply enough to avoid the two production-breaker bugs: stale cache reads leading to wrong decisions, and hot reconcile loops overwhelming the API server.

---

## The Kubernetes Go Client

`k8s.io/client-go` is the official Go client for the Kubernetes API. Two client variants matter:

| Client type | What it gives you | Use when |
|---|---|---|
| Typed (`kubernetes.Clientset`) | Generated, type-safe access to every built-in API group (core, apps, batch, …) | Working with Pods, Deployments, Services, ConfigMaps — anything in `k8s.io/api` |
| Dynamic (`dynamic.Interface`) | Untyped access via `unstructured.Unstructured`; no codegen required | Custom resources whose schema isn't compiled into your binary; generic tooling |

**Typed client from in-cluster ServiceAccount:**

```go
import (
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/rest"
)

cfg, err := rest.InClusterConfig() // reads /var/run/secrets/kubernetes.io/serviceaccount/token
if err != nil {
    return fmt.Errorf("in-cluster config: %w", err)
}
clientset, err := kubernetes.NewForConfig(cfg)
if err != nil {
    return fmt.Errorf("build clientset: %w", err)
}
```

**For local development**, use `clientcmd` to load `~/.kube/config`:

```go
import "k8s.io/client-go/tools/clientcmd"

cfg, err := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
    clientcmd.NewDefaultClientConfigLoadingRules(),
    &clientcmd.ConfigOverrides{},
).ClientConfig()
```

**Dynamic client for unstructured access:**

```go
import (
    "k8s.io/client-go/dynamic"
    "k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
    "k8s.io/apimachinery/pkg/runtime/schema"
)

dynClient, _ := dynamic.NewForConfig(cfg)
gvr := schema.GroupVersionResource{
    Group:    "mygroup.io",
    Version:  "v1alpha1",
    Resource: "myresources",
}
obj, err := dynClient.Resource(gvr).Namespace("default").Get(ctx, "myobj", metav1.GetOptions{})
image, _, _ := unstructured.NestedString(obj.Object, "spec", "image")
```

The dynamic client is the right tool when the CRD schema is not compiled into your binary — a generic operator that manages resources it discovers at runtime, or a CLI that talks to arbitrary custom resources.

---

## Informers and the Work Queue

Polling the API server on every reconcile would bring it to its knees at any meaningful scale. Informers solve this: they maintain a **local in-memory cache** backed by a long-running Watch against the API server, and they push reconcile requests into a work queue when objects change.

```
API server (etcd)
     │
     │  Watch (long-lived streaming HTTP/2 call)
     ▼
SharedIndexInformer ── in-memory cache (thread-safe, indexed)
     │
     │  OnAdd / OnUpdate / OnDelete event handlers
     ▼
RateLimitingWorkQueue ── deduplicated, exponential back-off on retry
     │
     │  controller goroutine pops items
     ▼
Reconciler.Reconcile(ctx, Request{NamespacedName: ...})
```

**Key properties of the work queue:**

- **Deduplication.** If an object is updated five times before the controller processes the first event, only one reconcile is queued — not five. The reconcile sees the *current* state, not a replay of each intermediate state.
- **Rate limiting.** Retried items back off exponentially (default: base 5ms, max 1000s). A broken reconcile does not hammer the API server.
- **No loss on restart.** When the controller starts, the informer performs a full List to seed the cache, then a Watch for changes. Everything existing is re-queued on start-up. This is why reconciles must be idempotent.

You do not wire informers and queues manually when using `controller-runtime` — the `Manager` does it. But knowing they exist explains *why* reconciles may be called more than once per change, and *why* you should never assume the order or frequency of calls.

---

## controller-runtime: Manager and Reconciler

`sigs.k8s.io/controller-runtime` is the framework kubebuilder and operator-sdk scaffold on top of. Two core types:

**Manager** — the process-level container. Owns the shared informer cache, the webhook server, leader election, health and metrics endpoints:

```go
import ctrl "sigs.k8s.io/controller-runtime"

mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
    Scheme:                 scheme,
    MetricsBindAddress:     ":8080",
    HealthProbeBindAddress: ":8081",
    LeaderElection:         true,
    LeaderElectionID:       "myoperator.mygroup.io",
})
if err != nil {
    return fmt.Errorf("new manager: %w", err)
}
```

Start the manager (blocks until context cancellation or fatal error):

```go
if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
    return fmt.Errorf("manager start: %w", err)
}
```

**Reconciler** — the interface you implement. Called by the framework with the name+namespace of an object that needs attention:

```go
type MyReconciler struct {
    client.Client          // embedded — gives r.Get, r.Create, r.Update, r.Patch, r.Delete
    Scheme *runtime.Scheme
}

func (r *MyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log := log.FromContext(ctx)

    var obj myv1alpha1.MyResource
    if err := r.Get(ctx, req.NamespacedName, &obj); err != nil {
        if apierrors.IsNotFound(err) {
            return ctrl.Result{}, nil // object deleted before we got here — nothing to do
        }
        return ctrl.Result{}, fmt.Errorf("get %s: %w", req.NamespacedName, err)
    }

    log.Info("reconciling", "resource", obj.Name)

    // ... reconcile logic ...

    return ctrl.Result{}, nil
}
```

Register the reconciler with the manager:

```go
if err := ctrl.NewControllerManagedBy(mgr).
    For(&myv1alpha1.MyResource{}).
    Owns(&appsv1.Deployment{}).   // also trigger when an owned Deployment changes
    Complete(&MyReconciler{
        Client: mgr.GetClient(),
        Scheme: mgr.GetScheme(),
    }); err != nil {
    return fmt.Errorf("setup controller: %w", err)
}
```

`For(&myv1alpha1.MyResource{})` watches the primary resource. `.Owns(&appsv1.Deployment{})` also triggers a reconcile when an owned Deployment changes — so if someone manually edits a Deployment your controller manages, the controller immediately corrects it.

---

## The Reconcile Loop and Idempotency

The reconcile model: **read the world, compare to desired state, act to close the gap.** The function must be idempotent — calling it twice in a row with no external changes must produce the same outcome and no side effects.

```go
func (r *MyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    var resource myv1alpha1.MyResource
    if err := r.Get(ctx, req.NamespacedName, &resource); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // Build the desired Deployment
    desired := r.buildDeployment(&resource)

    // Try to get the existing one
    var existing appsv1.Deployment
    err := r.Get(ctx, types.NamespacedName{
        Name:      desired.Name,
        Namespace: desired.Namespace,
    }, &existing)

    if apierrors.IsNotFound(err) {
        // Does not exist — create it and return (cache updates asynchronously)
        if err := r.Create(ctx, desired); err != nil {
            return ctrl.Result{}, fmt.Errorf("create deployment: %w", err)
        }
        return ctrl.Result{}, nil
    }
    if err != nil {
        return ctrl.Result{}, fmt.Errorf("get deployment: %w", err)
    }

    // Exists — patch only if different (avoids spurious write events)
    if existing.Spec.Replicas != nil &&
        *existing.Spec.Replicas == *desired.Spec.Replicas {
        return ctrl.Result{}, nil // nothing to do
    }

    patch := client.MergeFrom(existing.DeepCopy())
    existing.Spec.Replicas = desired.Spec.Replicas
    if err := r.Patch(ctx, &existing, patch); err != nil {
        return ctrl.Result{}, fmt.Errorf("patch deployment: %w", err)
    }

    return ctrl.Result{}, nil
}
```

**Patch vs Update.** Always use `r.Patch` rather than `r.Update` for modifications. `Update` replaces the entire object spec and fails with a `Conflict` error if the `resourceVersion` has changed since you read it (common under concurrent reconciles or controller restarts). `Patch` sends only the diff, is conflict-resilient, and cannot accidentally clobber fields managed by other controllers or the admission webhook. Use `client.MergeFrom(obj.DeepCopy())` to capture the before-state for a strategic merge patch.

**ctrl.Result variants:**

```go
return ctrl.Result{}, nil                              // done — only re-reconcile on a Watch event
return ctrl.Result{RequeueAfter: 30 * time.Second}, nil  // re-reconcile after 30s (poll pattern)
return ctrl.Result{}, fmt.Errorf("...")                // error — requeued with exponential back-off
return ctrl.Result{Requeue: true}, nil                 // immediate requeue — use sparingly
```

Never return `ctrl.Result{Requeue: true}` in a tight loop without `RequeueAfter` — it becomes a busy loop against the API server.

---

## Owner References and Garbage Collection

When your controller creates a child resource (Deployment, Service, ConfigMap), set an owner reference so Kubernetes garbage-collects the child when the parent is deleted:

```go
import "sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

desired := r.buildDeployment(&resource)
if err := controllerutil.SetControllerReference(&resource, desired, r.Scheme); err != nil {
    return ctrl.Result{}, fmt.Errorf("set owner ref: %w", err)
}
```

`SetControllerReference` writes an `ownerReferences` entry with `controller: true` on the child. When the parent is deleted, the garbage collector cascades the deletion to every owned child. Without owner references, children are orphaned and accumulate over the cluster's lifetime.

Cross-namespace ownership is not supported (a parent and child must be in the same namespace, or the parent must be cluster-scoped). For cluster-scoped parents owning namespace-scoped children, use `controllerutil.SetOwnerReference` (without `controller: true`) and implement your own finalizer-based cleanup.

**Finalizers** block deletion of an object until you remove them — use them to run cleanup logic (external resources, cross-namespace children) before the parent object disappears:

```go
const myFinalizer = "mygroup.io/cleanup"

if !controllerutil.ContainsFinalizer(&resource, myFinalizer) {
    controllerutil.AddFinalizer(&resource, myFinalizer)
    return ctrl.Result{}, r.Update(ctx, &resource)
}

if !resource.DeletionTimestamp.IsZero() {
    // object is being deleted — run cleanup
    if err := r.cleanupExternalResources(ctx, &resource); err != nil {
        return ctrl.Result{}, err
    }
    controllerutil.RemoveFinalizer(&resource, myFinalizer)
    return ctrl.Result{}, r.Update(ctx, &resource)
}
```

---

## The Cache: Reader vs Writer

The `client.Client` embedded in your reconciler is backed by the Manager's shared informer cache for reads. **`r.Get` and `r.List` do not hit the API server — they read from the in-memory cache.** Writes (`r.Create`, `r.Update`, `r.Patch`, `r.Delete`) go directly to the API server.

```
r.Get / r.List  ────────→  informer CACHE  (eventually consistent with API server)
r.Create / r.Patch  ────→  API SERVER      (immediately durable; triggers a Watch event)
```

After a write, the cache is updated asynchronously when the API server's Watch event arrives. If you `r.Get` the same object immediately after `r.Create`, you may receive the old state — the object may not yet exist in the cache:

```go
r.Create(ctx, deployment)
// cache is NOT updated yet — Watch event is in flight
r.Get(ctx, key, &deployment) // may return NotFound or pre-creation state
```

The reconcile loop handles this naturally: the creation generates a Watch event, which triggers a fresh reconcile, and by that time the cache is consistent. The pattern: **return after each write and let the next reconcile see the updated state**.

```go
if apierrors.IsNotFound(err) {
    return ctrl.Result{}, r.Create(ctx, desired) // return — do not read-after-write
}
```

The one exception is reading status after updating spec: use `r.Status().Update` for status-only writes and `r.Status().Patch` to avoid clobbering spec fields. Status is a sub-resource — writing it separately avoids a `Conflict` from a concurrent spec write.

---

## Debugging client-go and controller-runtime

| Symptom | Likely cause | Fix |
|---|---|---|
| Reconciler reads stale state immediately after a write in the same call | Informer cache has not received the Watch event yet | Return after each write; never read-after-write in the same reconcile iteration |
| Reconcile loops continuously at high rate (metrics show >5 reconciles/s for one object) | Returning `Requeue: true` every time, or every patch/update triggers a Watch event that triggers a reconcile that patches again | Use `RequeueAfter` for poll patterns; add a semantic equality check before patching — return early if state is already desired |
| `forbidden: User "system:serviceaccount:..." cannot list/get/watch ...` | Controller's ServiceAccount lacks RBAC for the resources it accesses | Add the missing verb+resource to the ClusterRole bound to the controller SA; use `//+kubebuilder:rbac:groups=...,resources=...,verbs=...` markers and regenerate, or edit the ClusterRole directly |
| `no kind is registered for the type ... in scheme` | CRD type not added to the `runtime.Scheme` before starting the Manager | Call `myv1alpha1.AddToScheme(scheme)` before `ctrl.NewManager(..., ctrl.Options{Scheme: scheme})` |
| Child resource not deleted when parent is deleted | Owner reference missing, or set with wrong TypeMeta (GVK) | Use `controllerutil.SetControllerReference`; verify with `kubectl get <child> -o jsonpath='{.metadata.ownerReferences}'` |
| `conflict: the object has been modified; please apply your changes to the latest version` | Using `r.Update` and the `resourceVersion` changed between your `r.Get` and the `r.Update` | Switch to `r.Patch` with `client.MergeFrom(obj.DeepCopy())` — patch is conflict-resilient |
| Controller SA permissions look correct but requests still fail with 403 | RBAC is namespace-scoped (Role/RoleBinding) but resource is cluster-scoped, or vice versa | Cluster-scoped resources require ClusterRole + ClusterRoleBinding; namespace-scoped resources need Role + RoleBinding in the correct namespace |

> **War story.** On a SAP operator managing tenant-scoped resources, `reconcile_total` in Prometheus climbed at 50/s for a single tenant object — a feedback loop. Root cause: the reconciler called `r.Update` on the object's status after every reconcile, which bumped `resourceVersion`, which triggered a Watch event, which triggered a reconcile, which called `r.Update` again. Infinite loop at API-server cost. The fix had two parts: switch from `r.Update` to `r.Status().Patch` with `client.MergeFrom(obj.DeepCopy())`, and add a semantic equality check before patching — if the computed status was already equal to the observed status, return with no write. The loop stopped immediately. We added a Grafana alert in LGTM: if the per-object reconcile rate exceeds 5/s for any NamespacedName, page. The informer model means *every write triggers a reconcile* — writing unconditionally guarantees a feedback loop. Make every write conditional on actual change.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Explain the difference between the typed `kubernetes.Clientset` and the dynamic client; name one concrete use case for each.
2. Describe what an informer does, what the work queue's deduplication property means for reconcile frequency, and why this forces reconciles to be idempotent.
3. Write the skeleton of a `Reconcile` function that handles `NotFound` correctly and uses `Patch` instead of `Update`.
4. Explain why `r.Get` immediately after `r.Create` in the same reconcile call may return stale data, and what the correct pattern is.
5. Describe a hot reconcile loop: how it starts, what Prometheus metric reveals it, and what two code changes stop it.
6. Explain what `controllerutil.SetControllerReference` does, why you need it, and what the observable symptom is if you omit it over a long-running cluster.
7. List the three RBAC objects required for a controller to read and write its target resources, and the exact `kubectl` command that reveals a permission error before the controller starts.

➡ Next up: **challenges** — build a real controller from scratch and validate it against a live kind cluster.
