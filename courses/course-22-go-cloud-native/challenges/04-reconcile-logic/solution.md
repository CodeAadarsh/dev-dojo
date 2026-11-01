# Solution — Reconcile Logic

The complete `reconciler.go`. Key decisions explained below the code.

```go
package reconcilelogic

import (
	"context"
	"fmt"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

func Reconcile(ctx context.Context, c client.Client, widget *Widget) error {
	deploy := &appsv1.Deployment{}
	err := c.Get(ctx, types.NamespacedName{Name: widget.Name, Namespace: widget.Namespace}, deploy)

	if apierrors.IsNotFound(err) {
		replicas := widget.Spec.Replicas
		return c.Create(ctx, &appsv1.Deployment{
			ObjectMeta: metav1.ObjectMeta{
				Name:      widget.Name,
				Namespace: widget.Namespace,
			},
			Spec: appsv1.DeploymentSpec{
				Replicas: &replicas,
				Selector: &metav1.LabelSelector{
					MatchLabels: map[string]string{"app": widget.Name},
				},
				Template: corev1.PodTemplateSpec{
					ObjectMeta: metav1.ObjectMeta{
						Labels: map[string]string{"app": widget.Name},
					},
					Spec: corev1.PodSpec{
						Containers: []corev1.Container{
							{Name: "widget", Image: widget.Spec.Image},
						},
					},
				},
			},
		})
	}
	if err != nil {
		return fmt.Errorf("getting Deployment %s/%s: %w", widget.Namespace, widget.Name, err)
	}

	if deploy.Spec.Replicas == nil || *deploy.Spec.Replicas != widget.Spec.Replicas {
		replicas := widget.Spec.Replicas
		deploy.Spec.Replicas = &replicas
		return c.Update(ctx, deploy)
	}
	return nil
}
```

## Why each piece is required

**`apierrors.IsNotFound(err)` rather than `err != nil`.**
`c.Get` can return many error types: 404 Not Found (expected first-time path), 503 Service Unavailable (transient), 403 Forbidden (RBAC gap), etc. Only `IsNotFound` means "the resource doesn't exist yet — create it." Treating any non-nil error as "not found" silently skips creation whenever the API is degraded, causing the controller to appear healthy while doing nothing. Always branch on `IsNotFound` first, then surface the general error.

**`replicas := widget.Spec.Replicas; deploy.Spec.Replicas = &replicas`.**
`appsv1.DeploymentSpec.Replicas` is `*int32` — a pointer. You cannot take the address of a struct field from an argument (`&widget.Spec.Replicas` would alias the caller's struct), so copy to a local variable first. This is the Go idiom for inline pointer-to-scalar.

**Idempotency gate (`*deploy.Spec.Replicas == widget.Spec.Replicas → return nil`).**
A naive reconcile that always calls `c.Update` fires a write to kube-apiserver on every reconcile iteration. In production this generates spurious `resourceVersion` conflicts, inflates audit logs, and can trigger rate-limit backoff. The guard `if *replicas != desired` skips the write when no change is needed — and the hidden test asserts this by calling Reconcile twice and verifying no error on the second call.

**`fmt.Errorf("... %w", err)` for non-NotFound errors.**
Wrapping the original error with `%w` preserves the chain for `errors.Is` callers upstream, while adding context (namespace/name) that makes on-call debugging faster. Never silently drop a non-NotFound error from `c.Get`.

## Hardening preview

In a real controller (not a dojo test) you would use `ctrl.CreateOrUpdate` instead of the hand-rolled get/create/update:

```go
_, err = ctrl.CreateOrUpdate(ctx, c, deploy, func() error {
    deploy.Spec.Replicas = &widget.Spec.Replicas
    // ... set rest of Spec
    return nil
})
```

`CreateOrUpdate` handles optimistic locking (`resourceVersion` conflicts) with automatic retries, which the hand-rolled version silently drops on update. `CreateOrUpdate` is the recommended pattern for production controllers.

## Apply and verify

```bash
cd ~/.kube-dojo-work/04-reconcile-logic
# replace reconciler.go with the solution above, then:
go test ./...
bash courses/course-22-go-cloud-native/challenges/04-reconcile-logic/verify.sh
```
