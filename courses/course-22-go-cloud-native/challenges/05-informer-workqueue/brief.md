# Informer + Workqueue

The event pipeline team filed a performance incident: *"Under load the handler is called 80 times per second for the same Pod — every watch event fires a direct dispatch. The handler does an expensive kube-apiserver GET on every call. CPU is pegged, latency is up, and we're hitting API rate limits."*

The root cause is that the naive implementation calls `handler(key)` once for every incoming event, including rapid-fire update events for the same object. The fix is the standard client-go pattern: wire an informer to a **rate-limited workqueue** so duplicate keys are collapsed before the handler sees them.

Your task: implement the `Controller` methods so the hidden go-test harness passes.

## Context

`setup.sh` plants a Go module in your work directory:

```
~/.kube-dojo-work/05-informer-workqueue/
├── go.mod             # module dojo/informer-workqueue; requires k8s.io + client-go
├── controller.go      # Controller stub — implement this
└── controller_test.go # visible smoke test
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/05-informer-workqueue
go mod tidy           # downloads k8s.io/api, k8s.io/apimachinery, k8s.io/client-go
go test -race ./...   # visible test (expect failures until implemented)
```

## Mission

Implement the five methods in `controller.go`:

| Method | Required behaviour |
|--------|-------------------|
| `New(handler)` | Create a `workqueue.RateLimitingInterface` via `workqueue.NewRateLimitingQueue(workqueue.DefaultControllerRateLimiter())` and return a `*Controller`. |
| `Enqueue(obj)` | Extract a `namespace/name` key via `cache.MetaNamespaceKeyFunc` and call `c.queue.Add(key)`. |
| `EnqueueDelete(obj)` | Like `Enqueue` but use `cache.DeletionHandlingMetaNamespaceKeyFunc` so `cache.DeletedFinalStateUnknown` tombstone objects are handled correctly. |
| `ProcessNext()` | Call `c.queue.Get()`. If the queue is shut down return `false`. Otherwise call `c.handler(key)`, then `c.queue.Done(item)`, return `true`. |
| `Shutdown()` | Call `c.queue.ShutDown()` (already stubbed; just ensure `New` sets the queue). |

The verify harness checks:

1. `Enqueue` + `ProcessNext` delivers the correct `namespace/name` key to the handler.
2. Enqueueing the same key twice before processing results in the handler being called **once** (workqueue dedup).
3. `EnqueueDelete` with a `cache.DeletedFinalStateUnknown` tombstone correctly delivers the key.
4. `ProcessNext` returns `false` after `Shutdown`.

## Why this matters

The informer + workqueue pattern is the backbone of every production Kubernetes controller. Three properties make it superior to direct dispatch:

- **Deduplication**: `queue.Add(key)` is idempotent while the key is in the dirty set. Fifty rapid-fire update events for the same Pod collapse to one handler call.
- **Rate limiting**: `DefaultControllerRateLimiter` applies per-item exponential backoff on re-queues and a bucket rate limit overall. This prevents a single crashlooping CR from burning all your API quota.
- **Key-based (not object-based)**: the queue stores `namespace/name` strings, not the object itself. The handler fetches the current object fresh from the informer's cache, which means it always sees the latest state regardless of how many events were coalesced.

## Verify

```bash
bash courses/course-22-go-cloud-native/challenges/05-informer-workqueue/verify.sh
```

All tests green → flag printed.
