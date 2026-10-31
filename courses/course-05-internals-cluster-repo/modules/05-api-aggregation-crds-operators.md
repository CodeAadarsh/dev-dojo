# Extending the API: CRDs, Aggregation & Operators

> **Module 05 · Course 05** — Kubernetes isn't a fixed set of object kinds; it's an API *platform* you extend. The moment you teach the API server a new noun — `Backup`, `KafkaCluster`, `CertificateRequest` — and write a controller that makes that noun *mean* something, you've built an operator. This module covers the two mechanisms for adding APIs (CRDs and aggregation), the controller/reconcile pattern that gives them behavior, and the judgment call of when a CRD beats a ConfigMap.

You already `kubectl get` CRDs installed by cert-manager, Prometheus Operator, or Argo at work. What separates competent from expert is understanding what a CRD *is* at the storage layer, why the reconcile loop is level-triggered not edge-triggered, and how an aggregated API server (like metrics-server) is fundamentally different from a CRD.

---

## Two ways to add an API

```
                    kube-apiserver
                          │
        ┌─────────────────┴──────────────────┐
        │                                     │
   CRD path                            Aggregation path
   (CustomResourceDefinition)          (APIService → your server)
        │                                     │
   apiextensions-apiserver             your HTTPS server handles
   stores CRs in the SAME etcd         the group/version itself
   under /registry/<group>/...         (own storage, own logic)
        │                                     │
   declarative schema, free            arbitrary behavior, you run
   storage + validation + watch        the server + its availability
```

| | **CRD** | **Aggregated API server** |
|---|---|---|
| You write | a YAML schema | an HTTPS server implementing the K8s API contract |
| Storage | reuses cluster etcd (`/registry/...`) | whatever you want (etcd, in-memory, a DB) |
| Validation | OpenAPI v3 schema + CEL rules | your code |
| Effort | minutes | a real service you must keep available |
| Use when | you're modeling *config/desired state* | you need computed/virtual resources, custom storage, or huge scale |
| Example | `Certificate`, `Prometheus`, `Rollout` | `metrics.k8s.io` (metrics-server), `custom.metrics.k8s.io` |

**95% of the time you want a CRD.** Reach for aggregation only when the resource isn't really "stored config" — e.g. `kubectl top` reads live, never-persisted metrics from an aggregated `metrics.k8s.io` API, which is why you don't see Pod metrics as objects in etcd.

---

## CustomResourceDefinitions: the real anatomy

A CRD teaches the API server a new kind. Here's a complete, runnable one — a `Backup` resource with a validated schema, a status subresource, printer columns, and a short name:

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backups.dojo.example.com        # MUST be <plural>.<group>
spec:
  group: dojo.example.com
  names:
    kind: Backup
    plural: backups
    singular: backup
    shortNames: ["bk"]
  scope: Namespaced                       # or Cluster
  versions:
    - name: v1alpha1
      served: true
      storage: true                       # exactly ONE version has storage:true
      subresources:
        status: {}                        # splits /status so spec & status update separately
      additionalPrinterColumns:
        - name: Target
          type: string
          jsonPath: .spec.target
        - name: Phase
          type: string
          jsonPath: .status.phase
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
      schema:
        openAPIV3Schema:
          type: object
          required: ["spec"]
          properties:
            spec:
              type: object
              required: ["target", "schedule"]
              properties:
                target:
                  type: string
                  description: "PVC or namespace to back up"
                schedule:
                  type: string
                  pattern: '^(@(hourly|daily|weekly))$'   # enforced at admission
                retention:
                  type: integer
                  minimum: 1
                  maximum: 90
                  default: 7
              # CEL validation rule — rejected before it ever hits etcd
              x-kubernetes-validations:
                - rule: "self.retention <= 30 || self.schedule != '@hourly'"
                  message: "hourly backups may keep at most 30 copies"
            status:
              type: object
              properties:
                phase:
                  type: string
                lastBackupTime:
                  type: string
```

Create it and the API server instantly serves a new REST endpoint — no restart:

```bash
kubectl apply -f backup-crd.yaml
kubectl get crd backups.dojo.example.com          # should say Established
kubectl api-resources | grep backups              # now a first-class noun
kubectl explain backup.spec                        # your schema powers explain!

cat <<'YAML' | kubectl apply -f -
apiVersion: dojo.example.com/v1alpha1
kind: Backup
metadata:
  name: nightly-db
  namespace: default
spec:
  target: dojo-data/postgres
  schedule: "@daily"
  retention: 14
YAML

kubectl get backups        # -> uses your printer columns: TARGET PHASE AGE
kubectl get bk             # shortName works too
```

Points that trip people up:

- **`storage: true` on exactly one version.** That's the version persisted in etcd. Others are served and *converted* to/from it.
- **Conversion between versions.** With only schema changes you use strategy `None` (fields map 1:1). Structural changes need a **conversion webhook** — a service the API server calls to translate `v1alpha1 ↔ v1`. Skipping this is why a sloppy `v1alpha1 → v1` bump returns `conversion webhook ... connection refused` and makes *all* reads of that CRD fail.
- **The status subresource is not cosmetic.** With `subresources.status: {}`, a controller updating `.status` via the `/status` endpoint won't bump `.metadata.generation`, so it won't trigger its own reconcile — that's how you avoid a hot loop (more below).
- **CEL via `x-kubernetes-validations`** runs validation *in the API server* at admission, no webhook needed — cheap, synchronous, and impossible to bypass.

---

## The controller/operator pattern: watch → reconcile

A CRD with no controller is inert YAML in etcd. The **operator** is the controller that gives it behavior. The core loop is deceptively simple and worth internalizing exactly:

```
  ┌──────────── the reconcile loop ────────────┐
  │                                             │
  │  watch(Backup) ──► workqueue ──► Reconcile(key)
  │                                     │
  │   1. GET current object (desired)   │
  │   2. observe actual world (CronJob? │
  │      PVC snapshot? status?)         │
  │   3. compute diff, make ONE step    │
  │      toward desired                 │
  │   4. update .status                 │
  │   5. return (ok) | (requeue after)  │
  │                                     │
  └── re-fired on ANY change OR resync ─┘
```

Three properties make this robust, and each is a common interview question:

- **Level-triggered, not edge-triggered.** Reconcile is handed a *key* ("Backup/default/nightly-db"), not a diff. It re-reads the full desired and actual state every time. A missed event doesn't matter — the periodic resync (and the next change) will converge anyway. Never write a controller that assumes it saw every transition.
- **Idempotent.** Reconcile may run twice for one change, or run when nothing changed. Every action must be "create if absent, update if drifted" — `kubectl apply`-style — never "append" or "increment."
- **One step, then requeue.** Don't block the worker for 10 minutes waiting for a backup to finish. Kick it off, write `status.phase: Running`, `return ctrl.Result{RequeueAfter: 30s}`, and check again next pass.

Minimal reconcile skeleton (controller-runtime, the de-facto standard under Kubebuilder/Operator SDK):

```go
func (r *BackupReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    var bk dojov1alpha1.Backup
    if err := r.Get(ctx, req.NamespacedName, &bk); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)   // deleted — nothing to do
    }

    desired := buildCronJob(&bk)                            // pure function of spec
    if err := ctrl.SetControllerReference(&bk, desired, r.Scheme); err != nil {
        return ctrl.Result{}, err                           // owner ref → GC + re-fire
    }

    var existing batchv1.CronJob
    switch err := r.Get(ctx, key(desired), &existing); {
    case apierrors.IsNotFound(err):
        if err := r.Create(ctx, desired); err != nil { return ctrl.Result{}, err }
    case err == nil:
        existing.Spec = desired.Spec                        // reconcile drift
        if err := r.Update(ctx, &existing); err != nil { return ctrl.Result{}, err }
    default:
        return ctrl.Result{}, err
    }

    bk.Status.Phase = "Scheduled"
    _ = r.Status().Update(ctx, &bk)                         // /status subresource
    return ctrl.Result{RequeueAfter: time.Minute}, nil
}
```

The **owner reference** (`SetControllerReference`) is the quiet hero: it makes the child CronJob get garbage-collected when the Backup is deleted, *and* wires a watch so changes to the child re-fire the parent's reconcile.

---

## When a CRD beats a ConfigMap

Both store structured data. The decision:

| Use a **CRD** when… | Use a **ConfigMap** when… |
|---|---|
| a controller watches and *acts* on it | app reads it as plain config at startup |
| you want schema validation / `kubectl explain` | arbitrary blobs, no validation needed |
| you want typed `kubectl get` + printer columns | key→value or file mounts |
| it's a first-class API with RBAC per-kind | RBAC on "configmaps" is fine |
| it has a lifecycle / status | it's inert |

Rule of thumb: **if something is going to watch it and reconcile toward it, it's a CRD. If something just reads it, it's a ConfigMap.** Shoving operator state into ConfigMaps ("the ConfigMap operator anti-pattern") throws away validation, status, and typed tooling, and you end up hand-rolling all of it in annotations.

---

## Aggregated API servers: the metrics-server case

metrics-server is the canonical aggregated API. It does **not** create CRDs. Instead it registers an `APIService` that tells the main API server "delegate the whole `metrics.k8s.io/v1beta1` group to me":

```bash
kubectl get apiservices | grep metrics
# v1beta1.metrics.k8s.io   kube-system/metrics-server   True

kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions}'
```

When you run `kubectl top nodes`, the request hits kube-apiserver, which *proxies* it to the metrics-server pod over HTTPS; metrics-server computes the answer from live kubelet data and returns it. Nothing is stored in etcd — that's the entire point of aggregation over CRDs here: Pod CPU/memory is a live, high-cardinality, never-persisted signal.

> Install it in this lab with `labs/bootstrap/install-metrics-server.sh` — note it patches `--kubelet-insecure-tls` because kind's kubelet serving certs are self-signed, which is itself a classic aggregated-API failure mode (TLS between the aggregator and the backing server).

---

## Debugging CRDs & operators

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `kubectl get crd` shows `Established: False` | name not `<plural>.<group>`, or no `storage: true` version, or bad schema | Fix metadata.name / mark one version storage; read the CRD's conditions |
| `kubectl apply` of a CR rejected | OpenAPI/CEL validation failed | Read the error; it names the field/rule; fix the CR or loosen the schema |
| `conversion webhook ... connection refused` on *every* read | conversion webhook service down / wrong CA | Fix the webhook deployment + `caBundle`; or drop to `conversion: strategy: None` if fields map 1:1 |
| CR created but nothing happens | no controller running, or RBAC missing on the CR | Check operator pod is up; verify its ServiceAccount has verbs on your group |
| Operator pegged at 100% CPU, status flapping | hot reconcile loop — writing spec on every pass, or no status subresource | Use the `/status` subresource; only write on actual drift; add rate limiting |
| `kubectl top` → `error: Metrics API not available` | aggregated APIService unavailable / TLS | Check `apiservice` condition + metrics-server logs + `--kubelet-insecure-tls` |

Diagnose each with the exact commands:

```bash
# why is a CRD not Established?
kubectl get crd backups.dojo.example.com -o jsonpath='{.status.conditions}'; echo
kubectl get crd backups.dojo.example.com -o jsonpath='{range .spec.versions[*]}{.name}{" storage="}{.storage}{"\n"}{end}'

# what exactly did validation reject? (apply client-side first to localize)
kubectl apply -f bad-cr.yaml --dry-run=server 2>&1 | tail

# is a controller even watching? find its pod + follow reconcile logs
kubectl get deploy -A | grep -iE 'operator|controller|manager'
kubectl -n <ns> logs deploy/<operator> --tail=100 -f

# does the operator's ServiceAccount have rights on your CRD group?
kubectl auth can-i list backups.dojo.example.com \
  --as=system:serviceaccount:<ns>:<operator-sa>

# aggregated API health
kubectl get apiservices | grep -v True        # anything not True is a problem
kubectl -n kube-system logs deploy/metrics-server --tail=50

# watch a CR's status converge
kubectl get backups -w -o wide
```

> **War story.** A platform team shipped an operator that, on every reconcile, wrote a timestamp annotation onto its own CR "for observability." Because they'd forgotten the `status` subresource, each write bumped `.metadata.generation`, which re-triggered the watch, which reconciled, which wrote the annotation again — a self-sustaining loop. One operator pinned a control-plane core at 100%, flooded the audit log with thousands of `PATCH` calls per second, and the write pressure pushed **etcd** fsync latency past its threshold until the *whole cluster's* API went sluggish. A CRD defect took down far more than its own feature. The fixes stacked: move status to the `/status` subresource (so status writes don't bump generation), only write when state actually drifted, and add a `MaxConcurrentReconciles` + rate limiter. The meta-lesson: an operator has write access to your API and runs in a loop — treat a runaway reconcile as a potential cluster-wide incident, and always load-test it against a real resync storm before prod.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. State the two ways to extend the API and give the one-line rule for CRD vs aggregated API server.
2. Write a CRD from memory with a validated schema, a `status` subresource, and printer columns — and explain the `<plural>.<group>` name rule and `storage: true`.
3. Explain level-triggered + idempotent + requeue, and why a reconcile must never assume it saw every event.
4. Explain how the `status` subresource prevents a hot reconcile loop, and what an owner reference buys you (GC + re-fire).
5. Decide CRD vs ConfigMap for a given case and justify it in one sentence.
6. Explain why metrics-server is aggregated (not a CRD) and why `kubectl top` returns nothing that lives in etcd.

➡ Next up: **Admission Control & Webhooks** — you've extended *what* the API stores; now you'll intercept *every* write to mutate and validate it before it ever reaches etcd.
