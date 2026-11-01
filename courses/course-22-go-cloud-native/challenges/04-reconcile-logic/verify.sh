#!/usr/bin/env bash
# Verifier for "Reconcile Logic".
# Ships a hidden test file, runs go test ./..., and prints the flag on full pass.
set -uo pipefail

SLUG="04-reconcile-logic"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{reconcile_convergence_is_the_contract}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]            || fail "work directory missing — run setup.sh first"
[ -f "$WORK/go.mod" ]     || fail "go.mod missing — run setup.sh first"
[ -f "$WORK/reconciler.go" ] || fail "reconciler.go missing — run setup.sh first"

# ── ship hidden test ──────────────────────────────────────────────────────────
cat > "$WORK/reconciler_hidden_test.go" << 'GOEOF'
package reconcilelogic

import (
	"context"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestHidden_Idempotent(t *testing.T) {
	scheme := NewScheme()
	c := fake.NewClientBuilder().WithScheme(scheme).Build()
	ctx := context.Background()

	widget := &Widget{
		ObjectMeta: metav1.ObjectMeta{Name: "idem", Namespace: "default"},
		Spec:       WidgetSpec{Replicas: 3, Image: "nginx:1.27-alpine"},
	}
	if err := Reconcile(ctx, c, widget); err != nil {
		t.Fatalf("first Reconcile: %v", err)
	}
	if err := Reconcile(ctx, c, widget); err != nil {
		t.Fatalf("second Reconcile (idempotency): %v", err)
	}

	deploy := &appsv1.Deployment{}
	if err := c.Get(ctx, types.NamespacedName{Name: "idem", Namespace: "default"}, deploy); err != nil {
		t.Fatalf("Deployment not found: %v", err)
	}
	if deploy.Spec.Replicas == nil || *deploy.Spec.Replicas != 3 {
		t.Errorf("idempotency: want 3 replicas, got %v", deploy.Spec.Replicas)
	}
}

func TestHidden_UpdatesReplicas(t *testing.T) {
	scheme := NewScheme()
	c := fake.NewClientBuilder().WithScheme(scheme).Build()
	ctx := context.Background()

	widget := &Widget{
		ObjectMeta: metav1.ObjectMeta{Name: "scaleme", Namespace: "default"},
		Spec:       WidgetSpec{Replicas: 1, Image: "nginx:1.27-alpine"},
	}
	if err := Reconcile(ctx, c, widget); err != nil {
		t.Fatalf("first Reconcile: %v", err)
	}

	widget.Spec.Replicas = 5
	if err := Reconcile(ctx, c, widget); err != nil {
		t.Fatalf("second Reconcile after replica drift: %v", err)
	}

	deploy := &appsv1.Deployment{}
	if err := c.Get(ctx, types.NamespacedName{Name: "scaleme", Namespace: "default"}, deploy); err != nil {
		t.Fatalf("Deployment not found: %v", err)
	}
	if deploy.Spec.Replicas == nil || *deploy.Spec.Replicas != 5 {
		t.Errorf("drift fix: want 5 replicas, got %v", deploy.Spec.Replicas)
	}
}

func TestHidden_MultipleWidgets(t *testing.T) {
	scheme := NewScheme()
	c := fake.NewClientBuilder().WithScheme(scheme).Build()
	ctx := context.Background()

	names := []string{"alpha", "beta", "gamma"}
	for i, name := range names {
		widget := &Widget{
			ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
			Spec:       WidgetSpec{Replicas: int32(i + 1), Image: "nginx:1.27-alpine"},
		}
		if err := Reconcile(ctx, c, widget); err != nil {
			t.Fatalf("Reconcile %s: %v", name, err)
		}
	}

	for i, name := range names {
		deploy := &appsv1.Deployment{}
		if err := c.Get(ctx, types.NamespacedName{Name: name, Namespace: "default"}, deploy); err != nil {
			t.Fatalf("Deployment %s not found: %v", name, err)
		}
		want := int32(i + 1)
		if deploy.Spec.Replicas == nil || *deploy.Spec.Replicas != want {
			t.Errorf("Deployment %s: want %d replicas, got %v", name, want, deploy.Spec.Replicas)
		}
	}
}
GOEOF

cd "$WORK"
echo "Running go test ./... (visible + hidden tests)..."
echo
if go test ./... 2>&1; then
	echo
	echo "All tests passed. Submit this flag in the platform:"
	echo
	echo "    $FLAG"
else
	fail "test suite has failures — fix your Reconcile implementation and retry"
fi
