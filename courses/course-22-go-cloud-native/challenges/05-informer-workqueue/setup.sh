#!/usr/bin/env bash
# Plants the "Informer + Workqueue" Go module starter into the work directory.
# Idempotent — re-running overwrites source files, never deletes the module cache.
set -euo pipefail

SLUG="05-informer-workqueue"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

# ── go.mod ────────────────────────────────────────────────────────────────────
cat > "$WORK/go.mod" << 'EOF'
module dojo/informer-workqueue

go 1.22

require (
	k8s.io/api v0.29.3
	k8s.io/apimachinery v0.29.3
	k8s.io/client-go v0.29.3
)
EOF

# ── controller.go — implement this ───────────────────────────────────────────
cat > "$WORK/controller.go" << 'GOEOF'
package informerworkqueue

import (
	"k8s.io/client-go/util/workqueue"
)

// Controller wires informer events to a rate-limited work queue.
// The handler receives a deduplicated namespace/name key per object.
type Controller struct {
	queue   workqueue.RateLimitingInterface
	handler func(key string) error
}

// New returns a Controller backed by a new rate-limited queue.
// Use workqueue.NewRateLimitingQueue(workqueue.DefaultControllerRateLimiter()).
func New(handler func(key string) error) *Controller {
	// TODO: initialise c.queue and return the Controller
	return nil
}

// Enqueue extracts a namespace/name key from obj via cache.MetaNamespaceKeyFunc
// and calls c.queue.Add(key). Silently drops extraction errors.
//
// Typical informer wiring:
//
//	informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
//	    AddFunc:    c.Enqueue,
//	    UpdateFunc: func(_, new interface{}) { c.Enqueue(new) },
//	    DeleteFunc: c.EnqueueDelete,
//	})
func (c *Controller) Enqueue(obj interface{}) {
	// TODO: import "k8s.io/client-go/tools/cache" and use cache.MetaNamespaceKeyFunc
}

// EnqueueDelete is like Enqueue but uses cache.DeletionHandlingMetaNamespaceKeyFunc
// so cache.DeletedFinalStateUnknown tombstone objects (delivered on resync after a
// missed delete) are handled correctly.
func (c *Controller) EnqueueDelete(obj interface{}) {
	// TODO: use cache.DeletionHandlingMetaNamespaceKeyFunc
}

// ProcessNext pops one item from the queue, calls c.handler(key), marks Done,
// and returns true. Returns false when the queue is shut down.
func (c *Controller) ProcessNext() bool {
	// TODO: c.queue.Get() -> call handler -> c.queue.Done(item) -> return true
	//       return false on shutdown (second return value from Get is true)
	return false
}

// Shutdown stops the queue, unblocking any waiting ProcessNext callers.
func (c *Controller) Shutdown() {
	if c == nil || c.queue == nil {
		return
	}
	c.queue.ShutDown()
}
GOEOF

# ── controller_test.go — visible smoke test ───────────────────────────────────
cat > "$WORK/controller_test.go" << 'GOEOF'
package informerworkqueue

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestEnqueueAndProcess(t *testing.T) {
	var got string
	c := New(func(key string) error {
		got = key
		return nil
	})
	// If New is not yet implemented, the next line panics — implement New first.

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "my-pod", Namespace: "default"},
	}
	c.Enqueue(pod)
	c.ProcessNext()

	if got != "default/my-pod" {
		t.Fatalf("want 'default/my-pod', got %q", got)
	}
	c.Shutdown()
}
GOEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement New, Enqueue, EnqueueDelete, and ProcessNext"
echo "                 in controller.go so ALL tests pass (visible + hidden)."
echo "                 Key concepts: workqueue.NewRateLimitingQueue,"
echo "                 cache.MetaNamespaceKeyFunc, queue.Get/Done."
echo
echo "Prerequisites  :"
echo "  cd $WORK && go mod tidy   # downloads deps (internet required once)"
echo
echo "Run tests      : cd $WORK && go test -race ./..."
echo "Verify + flag  : bash courses/course-22-go-cloud-native/challenges/05-informer-workqueue/verify.sh"
