# Concurrency: Goroutines & Channels

> **Module 02 · Course 22** — Goroutines are cheap, but "cheap" does not mean "free." A production controller leaks goroutines on context cancellation, a handler deadlocks under load, and a concurrent map write panics in a race the test suite never caught. This module builds the mental model for writing Go concurrency correctly — not just quickly.

Go's concurrency proverb is: **share memory by communicating, not communicate by sharing memory**. Channels are the primary mechanism. Mutexes exist for the cases where a channel is the wrong tool. Understanding which is which is the whole game.

---

## Goroutines

A goroutine is a lightweight, cooperatively-scheduled coroutine managed by the Go runtime. Starting one is a single keyword:

```go
go func() {
    doWork()
}()
```

Initial stack: ~2–8 KB, grown as needed. The runtime multiplexes goroutines onto OS threads — `GOMAXPROCS` threads by default (equals the CPU count). You can run tens of thousands. The cost is real but not the bottleneck in most programs.

**The critical rule: every goroutine must have a way to terminate.** A goroutine that can't exit leaks — it holds live references, its stack can't be GC'd, and over time you exhaust memory. The most common cause is a goroutine blocking on a channel that is never closed or sent to after the caller moves on.

```go
// goroutine leak — 'ch' is never closed, goroutine blocks forever
ch := make(chan struct{})
go func() {
    <-ch      // blocks until close(ch) or a send
    cleanup()
}()
// if the caller exits without close(ch) or ch <- struct{}{}, the goroutine is gone for good
```

Always give goroutines a way out via `ctx.Done()` or a close of a coordination channel:

```go
go func() {
    for {
        select {
        case <-ctx.Done():
            return
        case msg := <-work:
            process(msg)
        }
    }
}()
```

---

## Channels

A channel is a typed, goroutine-safe FIFO queue with optional buffering.

```
Unbuffered channel (make(chan T)):
  send blocks until a receiver is ready
  receive blocks until a sender sends
  → both sides must meet at the channel simultaneously (synchronisation point)

Buffered channel (make(chan T, N)):
  send blocks only when the buffer is full
  receive blocks only when the buffer is empty
  → producer and consumer can proceed independently up to capacity N
```

```go
ch := make(chan int)       // unbuffered
ch := make(chan int, 10)   // buffered, capacity 10

// directional channel types enforce intent at compile time
func producer(out chan<- int) { out <- 42 }    // send-only; compile error on <-out
func consumer(in <-chan int) { v := <-in }     // receive-only; compile error on in <- x
```

**`close(ch)` is a broadcast.** Every goroutine blocking on `<-ch` unblocks simultaneously when the channel is closed, receiving the zero value and `ok==false`. This is the idiomatic "notify N goroutines to stop" mechanism:

```go
quit := make(chan struct{})
for i := 0; i < 5; i++ {
    go func(id int) {
        <-quit  // all five unblock at once when close(quit) is called
        fmt.Printf("worker %d exiting\n", id)
    }(i)
}
close(quit) // broadcast
```

A `ch <- struct{}{}` send only wakes one receiver. Never use it to stop a pool of workers — you'd have to send N times. Use `close`.

Reading from a closed channel drains the buffer first, then returns zero values forever. Use the two-value receive to detect closure:

```go
v, ok := <-ch
if !ok {
    // channel closed and drained
}
```

### select

`select` waits on multiple channel operations and executes the first ready case. If multiple are ready simultaneously, one is chosen at random (this is specified, not implementation-dependent):

```go
select {
case msg := <-incoming:
    handle(msg)
case <-ctx.Done():
    return ctx.Err()
case <-time.After(5 * time.Second):
    return errors.New("timeout")
default:
    // non-blocking: executes immediately if no other case is ready
}
```

The `default` case makes the select non-blocking. Use it intentionally — a tight loop with `select { default: ... }` is a busy-spin that wastes a CPU core.

---

## The "Share Memory by Communicating" Model

The proverb is a design philosophy, not a rule that channels are always the right tool:

```
Transferring ownership of data between goroutines   →  channel
Protecting concurrent access to shared state        →  mutex
Waiting for N goroutines to finish                  →  WaitGroup or errgroup
Bounding concurrency (semaphore pattern)            →  buffered channel
```

Choosing wrong shows up as either unnecessary complexity (using a channel to protect a counter that a single atomic would handle) or unsafe code (using a mutex where ownership transfer is the right model).

---

## sync Primitives

### sync.Mutex and sync.RWMutex

```go
type Cache struct {
    mu    sync.RWMutex
    store map[string]string
}

func (c *Cache) Get(key string) (string, bool) {
    c.mu.RLock()         // multiple concurrent readers allowed
    defer c.mu.RUnlock()
    v, ok := c.store[key]
    return v, ok
}

func (c *Cache) Set(key, val string) {
    c.mu.Lock()          // exclusive write — blocks all readers and other writers
    defer c.mu.Unlock()
    c.store[key] = val
}
```

Use `defer mu.Unlock()` immediately after `mu.Lock()` — it fires even on panic, preventing a deadlock in the recovery path.

`RWMutex` makes sense when reads heavily dominate. Under high write frequency, the bookkeeping cost of `RWMutex` can exceed the savings — benchmark with `go test -bench` before committing.

**Mutex copies are bugs.** A `sync.Mutex` (and `sync.WaitGroup`, `sync.Cond`) must not be copied after first use. Passing by value copies the internal state. The `go vet` tool catches this; `golangci-lint` surfaces it as `govet: copylocks`.

### sync.WaitGroup

```go
var wg sync.WaitGroup
for _, item := range items {
    wg.Add(1)
    go func(it Item) {
        defer wg.Done()
        process(it)
    }(item)
}
wg.Wait()
```

`wg.Add(N)` must be called before the goroutines start, not inside them. There is a race between `Wait` and `Done` if `Add` is called concurrently with `Wait`.

### errgroup

`golang.org/x/sync/errgroup` is WaitGroup + first-error collection + optional context cancellation in one:

```go
g, gctx := errgroup.WithContext(ctx)
for _, url := range urls {
    url := url  // loop variable capture (required pre-Go 1.22; a no-op in 1.22+)
    g.Go(func() error {
        return fetch(gctx, url)
    })
}
if err := g.Wait(); err != nil {
    return err  // first non-nil error from any goroutine
}
```

`errgroup.WithContext` cancels `gctx` when the first goroutine returns a non-nil error. Every goroutine that respects `gctx.Done()` exits promptly. Use `errgroup` instead of `WaitGroup` whenever any single failure should abort the rest.

---

## context for Cancellation and Deadlines

`context.Context` is the standard carrier for cancellation, deadlines, and request-scoped values across API boundaries.

Invariants:
- Pass `ctx` as the **first argument** to any function that does I/O or waits.
- Never store a `context.Context` in a struct — pass it through the call chain.
- The parent creates the context; children only observe it.
- `ctx.Done()` returns a channel that is closed when the context is cancelled or its deadline expires.

```go
ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
defer cancel() // always call cancel to release timer resources, even if the deadline fires first

resp, err := client.Do(req.WithContext(ctx))
if err != nil {
    if errors.Is(err, context.DeadlineExceeded) {
        // timed out
    }
    return fmt.Errorf("http request: %w", err)
}
```

**Propagation.** Pass the context into every sub-call, especially goroutines that do I/O:

```go
g.Go(func() error {
    return processItem(gctx, item) // gctx cancellation stops processItem cleanly
})
```

Not passing `ctx` means the goroutine outlives its deadline — the context leak pattern. The operation keeps running after the caller has given up, consuming resources and potentially mutating state the caller thinks it cancelled.

---

## The Race Detector

Go ships a built-in data race detector. Run it on tests and during development:

```bash
go test -race ./...
go run -race main.go
go build -race -o myapp-race .
```

The detector instruments every memory read and write at compile time and reports conflicts at runtime. False positives are essentially impossible — if the detector fires, there is a race.

A detected race looks like:

```
==================
WARNING: DATA RACE
Write at 0x00c00012a028 by goroutine 7:
  main.(*Counter).Inc()
      /home/user/app/main.go:18 +0x3c

Previous read at 0x00c00012a028 by goroutine 6:
  main.(*Counter).Value()
      /home/user/app/main.go:23 +0x2c
==================
```

The output shows the exact file, line, and goroutines involved — enough to fix it without guessing.

Overhead: ~2x memory, ~5–10x CPU. Run in tests and staging, never in production binaries.

---

## Debugging Concurrency

| Symptom | Likely cause | Fix |
|---|---|---|
| Service never exits cleanly; goroutine count grows over time | Goroutine leak — goroutines block on channels that are never closed or contexts that are never cancelled | Add `case <-ctx.Done(): return` to every goroutine loop; ensure `close(ch)` is called on all exit paths; expose `runtime.NumGoroutine()` via `/debug/vars` or pprof |
| `fatal error: all goroutines are asleep - deadlock!` | Every goroutine is blocked with no runnable path to unblock any of them | Draw the lock/channel dependency graph; look for a cycle; the error message names each blocked goroutine and its blocking call |
| `WARNING: DATA RACE` from `go test -race` | Two goroutines access the same memory, at least one writes, without synchronisation | Add a mutex, use `sync/atomic`, or send ownership through a channel; protect the complete read-modify-write as a unit |
| `sync: unlock of unlocked mutex` panic | `Unlock()` called when the mutex is not locked by any goroutine (or was already unlocked) | Ensure `Lock` and `Unlock` are always paired on the same goroutine; use `defer mu.Unlock()` immediately after `mu.Lock()` |
| Context cancellation does not stop a goroutine | `ctx` was not passed to the goroutine, or the goroutine ignores `ctx.Done()` | Add a `select { case <-ctx.Done(): return ctx.Err() }` at every blocking point; propagate `ctx` to every sub-call |
| `panic: close of closed channel` | Two goroutines both call `close(ch)` | Use `sync.Once` to guard the close: `o.Do(func() { close(ch) })` |
| `panic: concurrent map read and map write` | Concurrent map access without a mutex | Protect all map access with `sync.Mutex` (or use `sync.Map` for the specific concurrent-access patterns it supports) |

> **War story.** A SAP service processed log batches with a goroutine-per-batch pattern. Under our 100 GB/day load the goroutine count grew without bound — each goroutine called a downstream RPC, but the context passed to the gRPC call was `context.Background()`, not the request context. When the upstream HTTP request was cancelled (client disconnect), the gRPC call kept running for its full 30-second timeout. At peak, `runtime.NumGoroutine()` hit 40 000 and RSS tripled. The fix: pass the request context to every gRPC call so cancellation propagated. After the fix we added a `goroutines > 5000` alert in LGTM. Goroutine count became a first-class service health metric. The rule we wrote into the team's review checklist: every goroutine must have a ctx parameter, and every I/O call inside it must pass that ctx.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Explain why an unbuffered channel is a synchronisation point and a buffered channel is not. Give a concrete scenario where you'd choose each.
2. Write a goroutine that processes items from a channel and exits when a `context.Context` is cancelled, using a `select` statement.
3. Explain why `close(ch)` unblocks all receivers simultaneously, and why a single `ch <- struct{}{}` does not.
4. State the rule of thumb for channels vs mutexes and give one concrete scenario for each.
5. Write a fan-out over a slice using `errgroup` where the first error cancels remaining work.
6. Describe three things `go test -race` catches that code review alone cannot reliably detect.
7. Name the runtime call used to get the live goroutine count, and explain why it is a useful service health metric.

➡ Next up: **Errors, Modules & Tooling** — the plumbing that makes Go services maintainable at scale.
