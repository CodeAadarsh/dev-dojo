#!/usr/bin/env bash
# Plants the "Reconcile Logic" Go module starter into the work directory.
# Idempotent — re-running overwrites source files, never deletes the module cache.
set -euo pipefail

SLUG="04-reconcile-logic"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

# ── go.mod ────────────────────────────────────────────────────────────────────
cat > "$WORK/go.mod" << 'EOF'
module dojo/reconcile-logic

go 1.22

require (
	k8s.io/api v0.29.3
	k8s.io/apimachinery v0.29.3
	sigs.k8s.io/controller-runtime v0.17.3
)
EOF

# ── widget_types.go — provided, do not modify ─────────────────────────────────
cat > "$WORK/widget_types.go" << 'GOEOF'
package reconcilelogic

import (
	appsv1 "k8s.io/api/apps/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// SchemeGroupVersion is the group/version used to register Widget.
var SchemeGroupVersion = schema.GroupVersion{Group: "dojo.dev", Version: "v1"}

// Widget is a minimal custom resource for this challenge.
type Widget struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              WidgetSpec `json:"spec"`
}

// WidgetSpec is the desired state of a Widget.
type WidgetSpec struct {
	// Replicas is the number of pod replicas the backing Deployment should run.
	Replicas int32 `json:"replicas"`
	// Image is the container image for the backing Deployment.
	Image string `json:"image"`
}

func (w *Widget) DeepCopyObject() runtime.Object {
	out := *w
	return &out
}

// NewScheme returns a *runtime.Scheme with appsv1 and Widget registered.
// Use it to build the fake client: fake.NewClientBuilder().WithScheme(NewScheme()).Build()
func NewScheme() *runtime.Scheme {
	s := runtime.NewScheme()
	_ = appsv1.AddToScheme(s)
	s.AddKnownTypes(SchemeGroupVersion, &Widget{})
	metav1.AddToGroupVersion(s, SchemeGroupVersion)
	return s
}
GOEOF

# ── reconciler.go — implement this ───────────────────────────────────────────
cat > "$WORK/reconciler.go" << 'GOEOF'
package reconcilelogic

import (
	"context"

	"sigs.k8s.io/controller-runtime/pkg/client"
)

// Reconcile ensures a Deployment named widget.Name exists in widget.Namespace
// with spec.replicas == widget.Spec.Replicas and container image widget.Spec.Image.
//
// Invariants:
//  1. If no Deployment exists, create one.
//  2. If a Deployment exists with the wrong replica count, update it.
//  3. If a Deployment exists and is already at desired state, do nothing (no Update call).
//
// Useful identifiers:
//   - c.Get(ctx, types.NamespacedName{Name: ..., Namespace: ...}, deploy) to check existence.
//   - apierrors.IsNotFound(err) to distinguish "not found" from a real API error.
//   - c.Create(ctx, deploy) and c.Update(ctx, deploy) to write state.
//   - Build the Deployment Selector and pod Labels on "app": widget.Name.
func Reconcile(ctx context.Context, c client.Client, widget *Widget) error {
	// TODO: implement
	return nil
}
GOEOF

# ── reconciler_test.go — visible smoke test ───────────────────────────────────
cat > "$WORK/reconciler_test.go" << 'GOEOF'
package reconcilelogic

import (
	"context"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestReconcile_CreatesDeployment(t *testing.T) {
	scheme := NewScheme()
	c := fake.NewClientBuilder().WithScheme(scheme).Build()
	ctx := context.Background()

	widget := &Widget{
		ObjectMeta: metav1.ObjectMeta{Name: "my-widget", Namespace: "default"},
		Spec:       WidgetSpec{Replicas: 2, Image: "nginx:1.27-alpine"},
	}

	if err := Reconcile(ctx, c, widget); err != nil {
		t.Fatalf("Reconcile returned error: %v", err)
	}

	deploy := &appsv1.Deployment{}
	if err := c.Get(ctx, types.NamespacedName{Name: "my-widget", Namespace: "default"}, deploy); err != nil {
		t.Fatalf("expected Deployment to exist after Reconcile: %v", err)
	}
	if deploy.Spec.Replicas == nil || *deploy.Spec.Replicas != 2 {
		got := int32(0)
		if deploy.Spec.Replicas != nil {
			got = *deploy.Spec.Replicas
		}
		t.Errorf("want 2 replicas, got %d", got)
	}
}
GOEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement Reconcile in reconciler.go so ALL tests pass"
echo "                 (visible + hidden). The function must create, update,"
echo "                 and idempotently reconcile a Deployment for each Widget."
echo
echo "Prerequisites  :"
echo "  cd $WORK && go mod tidy   # downloads deps (internet required once)"
echo
echo "Run tests      : cd $WORK && go test ./..."
echo "Verify + flag  : bash courses/course-22-go-cloud-native/challenges/04-reconcile-logic/verify.sh"
