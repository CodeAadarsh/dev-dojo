# Reconcile Logic

The Platform team's Widget controller passed code review and the CI pipeline is green — because every test is calling `Reconcile` and blindly accepting `nil` back. The stub does nothing. In staging, no Widget CR ever gets a Deployment, and the on-call engineer opened a Jira: *"Reconciler is a no-op. Deployments never appear. Blocks Platform v2 launch."*

Your task: fill in `Reconcile` so the hidden go-test harness passes.

## Context

`setup.sh` plants a Go module in your work directory:

```
~/.kube-dojo-work/04-reconcile-logic/
├── go.mod             # module dojo/reconcile-logic; requires k8s.io + controller-runtime
├── widget_types.go    # Widget CR type + NewScheme() — do not modify
├── reconciler.go      # Reconcile stub — implement this
└── reconciler_test.go # visible smoke test
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/04-reconcile-logic
go mod tidy           # downloads controller-runtime, k8s.io/api, k8s.io/apimachinery
go test ./...         # visible smoke test (expect 1 failure until implemented)
```

## Mission

Implement `Reconcile(ctx, c, widget)` in `reconciler.go`. The function must:

| Condition | Required action |
|-----------|----------------|
| No Deployment named `widget.Name` in `widget.Namespace` | Create one with `spec.replicas == widget.Spec.Replicas` and container image `widget.Spec.Image` |
| Deployment exists, `spec.replicas` differs from `widget.Spec.Replicas` | Update `spec.replicas` |
| Deployment exists and is already at desired state | Do nothing — **no spurious Update calls** |

The verify harness checks all three conditions plus idempotency:

1. `Reconcile` for a new Widget creates exactly one Deployment with the right replica count.
2. A second identical `Reconcile` call succeeds without error and leaves replicas unchanged (idempotency).
3. Changing `widget.Spec.Replicas` and reconciling again updates the Deployment.
4. Multiple distinct Widgets each get their own isolated Deployment.

## Why this matters

The reconcile loop is the core of every Kubernetes controller. The invariant is: *after Reconcile returns nil, the cluster state must match the desired state declared in the CR.* Two properties make this correct in production:

- **Idempotency**: the controller runs repeatedly (reboots, re-lists, forced re-queues). A non-idempotent reconcile will duplicate resources or thrash on updates, causing service disruption.
- **Precise error handling**: `apierrors.IsNotFound(err)` distinguishes "resource doesn't exist yet" (expected path) from a genuine API error. Treating a 503 from kube-apiserver as "not found" silently skips creation and breaks the controller.

Both properties are testable in isolation with `sigs.k8s.io/controller-runtime/pkg/client/fake` — no cluster required.

## Verify

```bash
bash courses/course-22-go-cloud-native/challenges/04-reconcile-logic/verify.sh
```

All tests green → flag printed.
