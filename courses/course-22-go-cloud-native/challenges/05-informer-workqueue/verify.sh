#!/usr/bin/env bash
# Verifier for "Informer + Workqueue".
# Ships a hidden test file, runs go test -race ./..., prints the flag on full pass.
set -uo pipefail

SLUG="05-informer-workqueue"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{informer_and_workqueue_dedup_by_key}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]              || fail "work directory missing — run setup.sh first"
[ -f "$WORK/go.mod" ]       || fail "go.mod missing — run setup.sh first"
[ -f "$WORK/controller.go" ] || fail "controller.go missing — run setup.sh first"

# ── ship hidden test ──────────────────────────────────────────────────────────
cat > "$WORK/controller_hidden_test.go" << 'GOEOF'
package informerworkqueue

import (
	"sync/atomic"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/tools/cache"
)

func TestHidden_Dedup(t *testing.T) {
	var count int32
	c := New(func(key string) error {
		atomic.AddInt32(&count, 1)
		return nil
	})
	if c == nil {
		t.Fatal("New returned nil — implement New first")
	}

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "dup-pod", Namespace: "test"},
	}
	c.Enqueue(pod)
	c.Enqueue(pod) // same key already in dirty set — must be a no-op

	c.ProcessNext()

	if n := atomic.LoadInt32(&count); n != 1 {
		t.Errorf("want handler called 1 time (workqueue dedup), got %d", n)
	}
	c.Shutdown()
}

func TestHidden_DeleteTombstone(t *testing.T) {
	var got string
	c := New(func(key string) error {
		got = key
		return nil
	})
	if c == nil {
		t.Fatal("New returned nil — implement New first")
	}

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "gone-pod", Namespace: "staging"},
	}
	tombstone := cache.DeletedFinalStateUnknown{
		Key: "staging/gone-pod",
		Obj: pod,
	}
	c.EnqueueDelete(tombstone)
	c.ProcessNext()

	if got != "staging/gone-pod" {
		t.Errorf("want 'staging/gone-pod', got %q", got)
	}
	c.Shutdown()
}

func TestHidden_ShutdownReturnsFalse(t *testing.T) {
	c := New(func(key string) error { return nil })
	if c == nil {
		t.Fatal("New returned nil — implement New first")
	}
	c.Shutdown()
	if c.ProcessNext() {
		t.Error("ProcessNext should return false after Shutdown")
	}
}

func TestHidden_MultipleKeys(t *testing.T) {
	var keys []string
	c := New(func(key string) error {
		keys = append(keys, key)
		return nil
	})
	if c == nil {
		t.Fatal("New returned nil — implement New first")
	}

	pods := []struct{ ns, name string }{
		{"default", "pod-a"},
		{"default", "pod-b"},
		{"kube-system", "pod-c"},
	}
	for _, p := range pods {
		c.Enqueue(&corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{Name: p.name, Namespace: p.ns},
		})
	}
	for range pods {
		c.ProcessNext()
	}

	if len(keys) != 3 {
		t.Fatalf("want 3 unique keys processed, got %d: %v", len(keys), keys)
	}
	c.Shutdown()
}
GOEOF

cd "$WORK"
echo "Running go test -race ./... (visible + hidden tests)..."
echo
if go test -race ./... 2>&1; then
	echo
	echo "All tests passed. Submit this flag in the platform:"
	echo
	echo "    $FLAG"
else
	fail "test suite has failures — fix your Controller implementation and retry"
fi
