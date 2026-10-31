# Operators & CRDs

> **Module 03 · Course 09** — A CRD (CustomResourceDefinition) makes the Kubernetes API extensible: you define a new resource type, and it lives natively in etcd, accessible via `kubectl`, protected by RBAC, observable in events — just like a Deployment. An Operator pairs a CRD with a controller that watches instances of that CRD and drives the cluster toward the desired state. This is the architecture behind cert-manager, the Prometheus Operator, Argo CD, Crossplane, and most of the serious Kubernetes ecosystem.

You've used Operators (you apply a cert-manager `Certificate`, and TLS materializes). This module covers the other side: how to design a CRD schema that validates correctly, how the reconcile loop works, when you should write one versus reaching for a ConfigMap, and how to keep a controller from spinning or getting stuck.

---

## CRD fundamentals

A CRD is itself a Kubernetes object (kind `CustomResourceDefinition`) that teaches the API server about a new resource type:

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: databases.dojo.example.com   # must be <plural>.<group>
spec:
  group: dojo.example.com
  names:
    plural: databases
    singular: database
    kind: Database
    shortNames: [db]
  scope: Namespaced                  # or Cluster for non-namespaced resources
  versions:
    - name: v1alpha1
      served: true
      storage: true                  # exactly one version marked storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: [engine, storageGB]
              additionalProperties: false   # reject unknown fields
              properties:
                engine:
                  type: string
                  enum: [postgres, mysql]
                storageGB:
                  type: integer
                  minimum: 1
                  maximum: 500
                version:
                  type: string
                  default: "15"         # API server injects default if field absent
                highAvailability:
                  type: boolean
                  default: false
            status:
              type: object
              properties:
                phase:
                  type: string
                  enum: [Pending, Provisioning, Ready, Failed]
                endpoint:
                  type: string
                message:
                  type: string
      subresources:
        status: {}                    # enables /status subresource
        scale:                        # optional: enables HPA to target this CRD
          specReplicasPath: .spec.replicas
          statusReplicasPath: .status.replicas
      additionalPrinterColumns:
        - name: Engine
          type: string
          jsonPath: .spec.engine
        - name: Storage
          type: integer
          jsonPath: .spec.storageGB
        - name: Phase
          type: string
          jsonPath: .status.phase
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
```

Apply and wait for `Established` before creating instances:

```bash
kubectl apply -f database-crd.yaml
kubectl wait --for=condition=Established crd/databases.dojo.example.com --timeout=30s
kubectl get crd databases.dojo.example.com \
  -o jsonpath='{.status.conditions[?(@.type=="Established")].status}{"\n"}'
# -> True
```

Now `kubectl get db` works, `kubectl explain db.spec` reflects your schema, and the API server rejects any `Database` object that violates the `openAPIV3Schema`.

### Schema design rules

1. **Always set `type:` on every field.** Without it the field accepts anything (pre-structural-schema behavior). Structural schemas (every field typed) are required for pruning, defaulting, and conversion to work.
2. **Use `additionalProperties: false` on spec objects** to reject unknown fields at admission time rather than silently pruning them. Typos in spec keys become visible errors.
3. **`status` is never in `required`.** Status fields are set by the controller, not the user. The status subresource (`subresources: {status: {}}`) separates spec and status updates: a PATCH to the object body cannot change `.status`, and a PATCH to `/status` cannot change `.spec`.
4. **Defaults are API-server-side.** The `default:` in `openAPIV3Schema` is injected at admission if the field is absent — not in the controller. Controllers should not rely on defaults being set; they should handle the absent-field case defensively.

---

## Versions and conversion

A CRD can serve multiple versions simultaneously. The `storage: true` version is what etcd persists; other versions are served after runtime conversion:

```yaml
versions:
  - name: v1beta1
    served: true
    storage: false
    deprecated: true
    deprecationWarning: "v1beta1 is deprecated; use v1. Will be removed in 1.35."
    schema: ...
  - name: v1
    served: true
    storage: true
    schema: ...
```

When a client requests `v1beta1`, the API server converts the stored `v1` on the fly. This conversion is either **None** (trivial — same schema) or goes through a **conversion webhook**:

```yaml
spec:
  conversion:
    strategy: Webhook
    webhook:
      clientConfig:
        service:
          name: database-conversion-webhook
          namespace: dojo-operators
          path: /convert
      conversionReviewVersions: ["v1"]
```

The webhook receives a `ConversionReview` object and must return the object in the requested version. The standard pattern is to treat `v1` as the "hub": all versions convert to `v1` first, then to the target version.

Practical version graduation path:

| Stage | What to do |
|-------|-----------|
| Alpha | Ship `v1alpha1` with `storage: true`. Explicitly document "no stability guarantees." |
| Stabilizing | Add `v1`, set it `storage: true`, keep `v1alpha1` as `served: true` for one or two releases. |
| Deprecating | Set `deprecated: true` on `v1alpha1`, emit `deprecationWarning`. |
| Removal | Set `served: false` (removes API access for old version), then in a later release remove the version entry. |

Never set `served: false` and remove the CRD version entry in the same release — that breaks clients that haven't migrated yet.

---

## The controller reconcile loop

A controller is a process (usually Go) that watches Kubernetes objects and issues updates to reconcile actual state toward desired state:

```
Watch(Database)
  → event enqueued
    → Reconcile(namespacedName)
        ├── Fetch current Database from API server (not cache stale by default)
        ├── If deletionTimestamp set → run cleanup → remove finalizer → return
        ├── Compute desired child objects (StatefulSet, Service, Secret, …)
        ├── Server-side apply each child
        ├── Read actual child state
        ├── Update Database.Status
        └── Return (ctrl.Result, error)
              ├── non-nil error  → re-queue with exponential backoff
              ├── RequeueAfter   → re-queue after fixed delay (polling pattern)
              └── Result{}, nil  → done; re-queue only on next watch event
```

Critical properties of a correct reconciler:

**Idempotent.** Running Reconcile N times must produce the same outcome as running it once. The controller may be restarted mid-run; events can be re-delivered multiple times.

**Level-triggered, not edge-triggered.** Always compute the full desired state from the current spec — don't diff "what changed" against previous state. You'll receive the same object multiple times and your logic must be correct on any call.

**Short-circuit on generation.** `metadata.generation` increments on every spec change; status changes do not increment it. If `generation` equals `status.observedGeneration`, the spec hasn't changed since the last successful reconcile — you can skip expensive work and only re-check status:

```go
if db.Generation == db.Status.ObservedGeneration {
    // spec unchanged; only re-check child health if needed
    return r.reconcileStatus(ctx, db)
}
```

### Kubebuilder / Operator SDK concepts

Both frameworks generate boilerplate (manager setup, CRD scaffolding, RBAC markers) and let you focus on the Reconcile function:

```go
// kubebuilder pattern — simplified
func (r *DatabaseReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log := log.FromContext(ctx)

    db := &dojoexamplecomv1.Database{}
    if err := r.Get(ctx, req.NamespacedName, db); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err) // object deleted → stop reconciling
    }

    // Handle deletion
    if !db.DeletionTimestamp.IsZero() {
        if controllerutil.ContainsFinalizer(db, "databases.dojo.example.com/cleanup") {
            if err := r.cleanupExternalResources(ctx, db); err != nil {
                return ctrl.Result{}, err
            }
            controllerutil.RemoveFinalizer(db, "databases.dojo.example.com/cleanup")
            return ctrl.Result{}, r.Update(ctx, db)
        }
        return ctrl.Result{}, nil
    }

    // Add finalizer on first reconcile
    if !controllerutil.ContainsFinalizer(db, "databases.dojo.example.com/cleanup") {
        controllerutil.AddFinalizer(db, "databases.dojo.example.com/cleanup")
        return ctrl.Result{}, r.Update(ctx, db) // re-queues after update
    }

    // Build desired StatefulSet and server-side apply
    sts := r.buildStatefulSet(db)
    ctrl.SetControllerReference(db, sts, r.Scheme) // owner reference for GC
    if err := r.Patch(ctx, sts, client.Apply,
        client.ForceOwnership, client.FieldOwner("database-controller")); err != nil {
        return ctrl.Result{}, err
    }

    // Update status — always through /status subresource
    db.Status.Phase = "Ready"
    db.Status.ObservedGeneration = db.Generation
    if err := r.Status().Update(ctx, db); err != nil {
        return ctrl.Result{}, err
    }

    log.Info("Reconcile complete", "name", db.Name)
    return ctrl.Result{}, nil
}
```

RBAC markers (kubebuilder generates the ClusterRole from these):

```go
//+kubebuilder:rbac:groups=dojo.example.com,resources=databases,verbs=get;list;watch;create;update;patch;delete
//+kubebuilder:rbac:groups=dojo.example.com,resources=databases/status,verbs=get;update;patch
//+kubebuilder:rbac:groups=apps,resources=statefulsets,verbs=get;list;watch;create;update;patch;delete
```

### Running a minimal operator locally against kind-dojo

```bash
# With kubebuilder / controller-runtime:
make install          # generates and applies CRDs to current-context cluster
make run              # runs the controller binary outside the cluster using your local kubeconfig
                      # KUBECONFIG=~/.kube/config — kind-dojo works perfectly

# Create a test instance
kubectl apply -f config/samples/dojo_v1alpha1_database.yaml
kubectl get db -w   # watch status.phase update as the controller reconciles
```

---

## When CRDs beat ConfigMaps

The common anti-pattern: a team encodes configuration as a deeply-nested ConfigMap and writes a Deployment that watches it with inotify or a polling loop. This works until it doesn't.

| Capability | CRD | ConfigMap |
|------------|-----|-----------|
| Schema validation at admission (reject malformed config immediately) | Yes — `openAPIV3Schema` | No |
| Per-resource RBAC (only platform team can create `Database`) | Yes — RBAC on group/resource | No — only namespace-level RBAC on ConfigMaps |
| `kubectl` discovery (`kubectl get db`, `kubectl explain db.spec`) | Yes | No |
| Status subresource (controller reports phase, endpoint, error) | Yes | No — you'd need to write to a separate resource |
| Finalizers (block deletion until cleanup completes) | Yes | Technically yes, but semantically odd |
| Owner references (garbage-collect child objects automatically) | Yes | Yes |
| Admission webhooks (validate/mutate at creation/update time) | Yes | No |
| Versioning with conversion | Yes | No |

Use a CRD when: the configuration drives resource lifecycle (the controller creates/updates/deletes K8s objects in response), you need schema enforcement, or you want `kubectl` as the API. Use a ConfigMap when: it's truly just app configuration a process reads on startup, with no lifecycle operations.

---

## Finalizers & owner references

### Finalizers

A finalizer is a string in `metadata.finalizers`. Its presence blocks object deletion until a controller removes it:

```yaml
metadata:
  finalizers:
    - databases.dojo.example.com/cleanup
```

When a user runs `kubectl delete database mydb`, the API server sets `metadata.deletionTimestamp` but does not remove the object. The controller sees the non-zero timestamp, runs cleanup (drop the cloud DB, delete the PVC, remove DNS records), then removes the finalizer string. Once all finalizers are empty, the API server garbage-collects the object from etcd.

The Go pattern (seen in the reconcile loop above) is the canonical implementation. Never add a finalizer without writing the removal path — if the controller is uninstalled while objects with finalizers exist, those objects become permanently stuck: `kubectl delete` hangs forever.

Safe uninstall order for an operator that uses finalizers:
1. Delete all CR instances. Wait for their finalizers to clear and the objects to disappear.
2. Delete the controller Deployment (it's no longer needed).
3. Delete the CRD. (A CRD with existing instances cannot be deleted; this is why step 1 comes first.)

### Owner references

Owner references let the Kubernetes garbage collector cascade-delete child objects when the parent is deleted:

```yaml
# Set by the controller on child objects (StatefulSet, Service, Secret, …)
metadata:
  ownerReferences:
    - apiVersion: dojo.example.com/v1
      kind: Database
      name: mydb
      uid: a1b2c3d4-e5f6-7890-abcd-ef1234567890
      controller: true          # this owner is the managing controller
      blockOwnerDeletion: true  # block GC until this child is actually gone
```

In controller-runtime:

```go
ctrl.SetControllerReference(db, sts, r.Scheme)
```

With `blockOwnerDeletion: true`, deleting the parent waits until all blocking children are removed by the garbage collector — no finalizer code required for Kubernetes-managed resources. Use finalizers for *external* resources (cloud APIs, external databases); owner references for *Kubernetes* objects.

Cross-namespace owner references are not supported — if your controller creates cluster-scoped objects from a namespaced parent, you must use finalizers, not owner references.

---

## Debugging Operators & CRDs

Operator bugs often fail quietly — the reconcile loop runs but makes no progress, or it hot-loops and floods your logs.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `kubectl apply -f database.yaml` fails with `no kind "Database" is registered` | CRD not applied to cluster, or API group/version mismatch | `kubectl get crd databases.dojo.example.com`; if missing, apply the CRD manifest |
| `kubectl get crd` shows `ESTABLISHED: False` | Conversion webhook referenced in CRD spec is not reachable, or names conflict | `kubectl describe crd databases.dojo.example.com` → check Conditions; fix webhook Service/endpoint or set `strategy: None` |
| Controller log shows same object name reconciled every 1-3 seconds | Hot-loop: reconciler returns error on every attempt without making progress, or mutates spec in the reconciler triggering a watch event | Check logs for the specific error; ensure spec is never mutated in Reconcile (only status via `/status` subresource) |
| `kubectl delete database mydb` hangs (DeletionTimestamp set, object never disappears) | Finalizer present but controller not running or removal code has a bug | Confirm controller is running; check finalizer name for typos; emergency: patch finalizers to `[]` |
| CR created but fields in spec are silently ignored (schema doesn't reflect them) | Field missing from `openAPIV3Schema` — API server prunes unknown fields | Add the field; verify with `kubectl explain db.spec` showing the new field |
| `kubectl get db` returns no resources even though CRD is Established and instances exist | Wrong namespace, or listing wrong API version | `kubectl get db --all-namespaces`; `kubectl api-resources --api-group=dojo.example.com` to confirm group and resource name |

### Diagnose — exact commands

**CRD not Established.**

```bash
# Full condition dump — Message field has the root cause
kubectl describe crd databases.dojo.example.com | grep -A30 "Conditions:"

# NamesAccepted = False means a conflicting CRD exists (same group+plural, different name)
kubectl get crd | grep "dojo.example.com"

# Established = False with webhook strategy means the webhook endpoint is unreachable
kubectl -n dojo-operators get svc,endpoints database-conversion-webhook
```

**Reconcile hot-loop.**

```bash
# Watch controller logs — a hot-loop repeats the same NamespacedName every 1-3 seconds
kubectl -n dojo-operators logs deploy/database-controller -f | grep -E "Reconcil|error"

# Check if spec is being mutated inside Reconcile (triggers watch event → re-reconcile)
# Spec mutations in reconcile are the #1 cause of hot-loops
# The tell: reconcile count climbs without any user changes to the CR
kubectl -n dojo-operators get deploy database-controller \
  -o jsonpath='{.status.readyReplicas}{"\n"}'

# If the controller exposes Prometheus metrics (controller-runtime does by default):
kubectl -n dojo-operators port-forward deploy/database-controller 8080:8080 &
curl -s localhost:8080/metrics | grep controller_runtime_reconcile_total
# High error rate → look at the error counter
```

**Stuck finalizer — emergency removal.**

```bash
# Confirm the finalizer and deletion timestamp
kubectl get database mydb \
  -o jsonpath='{.metadata.finalizers}{"\t"}{.metadata.deletionTimestamp}{"\n"}'

# If controller is truly dead (CrashLoopBackOff, uninstalled) and cleanup is confirmed done:
kubectl patch database mydb \
  -p '{"metadata":{"finalizers":[]}}' \
  --type=merge
# Object disappears within seconds

# Never patch finalizers to [] without confirming external resources are cleaned up.
# In a cloud database scenario, orphaned external resources mean surprise billing.
```

> **War story.** At SAP the metering team shipped a `UsageRecord` CRD with a finalizer that flushed billing events to an external API before allowing deletion. During a quarterly maintenance window, a runbook step deleted the controller Deployment before deleting the `UsageRecord` instances — and then tried to delete the CRD. With the controller gone, no finalizers cleared. With live instances, the CRD deletion hung indefinitely (the API server won't remove a CRD with existing instances). The cluster was partially blocked for two hours while we manually patched the finalizer field on ~400 objects across three namespaces. The lesson became a formal rule: the operator's Helm chart has a `pre-delete` hook that creates a Job to delete all CR instances and waits for the namespace to drain before Helm removes the controller. The uninstall order is part of the operator's contract, not optional cleanup.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Write a minimal CRD with a `spec.engine: {enum: [postgres, mysql]}` field and an `additionalPrinterColumn` showing status phase.
2. Apply the CRD and verify it's `Established` with a single `kubectl` command.
3. Explain why `additionalProperties: false` matters for schema pruning, and what happens without it.
4. Describe the three reconcile return patterns and when to use each.
5. Write the deletion-path code in a Go reconciler: detect `DeletionTimestamp`, run cleanup, remove finalizer.
6. Set an owner reference on a child StatefulSet from a parent Database using `ctrl.SetControllerReference`.
7. Diagnose a hot-loop reconcile by reading controller logs and identifying the most common cause.
8. Issue the emergency patch command to remove a stuck finalizer and state what you must confirm first.
9. Name three capabilities a CRD gives you that a ConfigMap does not.
10. State the safe uninstall order for an operator that uses finalizers, and explain why that order matters.

➡ Next: **Crossplane** — if CRDs are how you extend the Kubernetes API, Crossplane is how you use that extension to provision cloud infrastructure through `kubectl`.
