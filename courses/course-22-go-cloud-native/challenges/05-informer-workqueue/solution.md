# Solution — Informer + Workqueue

The complete `controller.go`. Key decisions explained below.

```go
package informerworkqueue

import (
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/util/workqueue"
)

type Controller struct {
	queue   workqueue.RateLimitingInterface
	handler func(key string) error
}

func New(handler func(key string) error) *Controller {
	return &Controller{
		queue:   workqueue.NewRateLimitingQueue(workqueue.DefaultControllerRateLimiter()),
		handler: handler,
	}
}

func (c *Controller) Enqueue(obj interface{}) {
	key, err := cache.MetaNamespaceKeyFunc(obj)
	if err != nil {
		return
	}
	c.queue.Add(key)
}

func (c *Controller) EnqueueDelete(obj interface{}) {
	key, err := cache.DeletionHandlingMetaNamespaceKeyFunc(obj)
	if err != nil {
		return
	}
	c.queue.Add(key)
}

func (c *Controller) ProcessNext() bool {
	item, quit := c.queue.Get()
	if quit {
		return false
	}
	defer c.queue.Done(item)
	if key, ok := item.(string); ok {
		_ = c.handler(key)
	}
	return true
}

func (c *Controller) Shutdown() {
	if c == nil || c.queue == nil {
		return
	}
	c.queue.ShutDown()
}
```

## Why each piece is required

**`workqueue.NewRateLimitingQueue(workqueue.DefaultControllerRateLimiter())`.**
`DefaultControllerRateLimiter()` returns a composite limiter: an item-level exponential backoff (5ms → 1000s) that backs off retrying failed items, plus a bucket overall rate limiter (10 r/s burst 100). If you used `workqueue.NewQueue()` (no rate limiting), a single crashlooping CR could saturate the kube-apiserver with GET requests in seconds.

**`cache.MetaNamespaceKeyFunc(obj)` returns `"namespace/name"` (or just `"name"` for cluster-scoped objects).**
The queue stores *keys*, not objects. When `ProcessNext` drains a key, the handler fetches the current state from the informer's local cache (`Lister`) — not from the API. This decouples event delivery from processing: 50 events collapse to one fetch of the latest object.

**`cache.DeletionHandlingMetaNamespaceKeyFunc(obj)` for delete events.**
When a watch resync fires for a deleted object, the informer may deliver a `cache.DeletedFinalStateUnknown{Key: "ns/name", Obj: lastKnownState}` tombstone instead of the raw object. `MetaNamespaceKeyFunc` panics on tombstones; `DeletionHandlingMetaNamespaceKeyFunc` checks for the tombstone type and extracts the `Key` field directly. Forgetting this is a common source of `"unexpected type"` panics in controllers at resync time.

**`defer c.queue.Done(item)` — always call Done.**
`queue.Get` moves the item from the *dirty* set to the *processing* set. `Done` removes it from processing. If you forget `Done`, any subsequent `Add(sameKey)` that arrived while processing will never be re-queued because the item is stuck in the processing set forever. This creates a silent event-loss bug that only manifests after the first re-queue of a given key.

**`item.(string)` type assertion.**
The workqueue stores `interface{}`. Keys were added as `string` via `cache.MetaNamespaceKeyFunc`, so the assertion is safe. If you ever add non-string items to the queue, this will panic — which is intentional (a programming error, not a runtime condition).

## Wire it to a real informer

In production, wire the controller's event handlers to a `cache.SharedIndexInformer`:

```go
informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
    AddFunc:    c.Enqueue,
    UpdateFunc: func(_, new interface{}) { c.Enqueue(new) },
    DeleteFunc: c.EnqueueDelete,
})
go informer.Run(stopCh)
cache.WaitForCacheSync(stopCh, informer.HasSynced)

// start worker goroutines
for i := 0; i < workers; i++ {
    go func() {
        for c.ProcessNext() {}
    }()
}
```

`WaitForCacheSync` blocks until the informer's local cache is populated from the initial list. Starting workers before sync causes the handler to see stale or missing objects on first pass.

## Apply and verify

```bash
cd ~/.kube-dojo-work/05-informer-workqueue
# replace controller.go with the solution above, then:
go test -race ./...
bash courses/course-22-go-cloud-native/challenges/05-informer-workqueue/verify.sh
```
