# Solution — Bounded Worker Pool

Complete `pool.go`. Copy this in, then run the verifier.

```go
package pool

import "sync"

// WorkerPool starts exactly n goroutines. Each goroutine ranges over jobs
// (safe: channel receive is concurrency-safe by design) and writes Results.
// WaitGroup tracks goroutine lifetime; close(results) happens only after
// all n workers have exited — the single safe ordering.
func WorkerPool(n int, jobs <-chan Job, results chan<- Result, transform func(int) int) {
	var wg sync.WaitGroup
	wg.Add(n)
	for range n {
		go func() {
			defer wg.Done()
			for job := range jobs {
				results <- Result{JobID: job.ID, Output: transform(job.Input)}
			}
		}()
	}
	wg.Wait()
	close(results)
}
```

## Why each piece is correct

**`for range n`** (Go 1.22 range-over-integer) starts exactly `n` goroutines.
Using `for i := 0; i < n; i++` is equivalent; the 1.22 form is terser and
removes the loop variable entirely.

**`wg.Add(n)` before the loop, not `wg.Add(1)` inside the loop.** Adding inside
the loop races: if all goroutines finish before the main goroutine reaches the
next `wg.Add(1)`, `wg.Wait()` might unblock prematurely. The rule: call `Add`
*before* spawning the goroutines it counts.

**`defer wg.Done()`** guarantees the decrement happens even if `transform`
panics. Without `defer`, a panicking transform leaves the WaitGroup counter
stuck above zero and `wg.Wait()` never returns.

**`for job := range jobs`** — channels are the synchronisation mechanism.
Multiple goroutines can receive from the same channel concurrently; the runtime
guarantees each send is received by exactly one goroutine. No mutex needed
around the receive side.

**`close(results)` after `wg.Wait()`** — the only safe ordering. Two wrong
alternatives:
- Close inside a goroutine: the first goroutine to finish would close the
  channel while other workers might still be writing → panic: send on closed channel.
- Close before `wg.Wait()`: same race — main goroutine closes while a worker
  is still mid-write.

The pattern is: WaitGroup counts *all* writers; `close` is called by the one
goroutine that owns the channel (here: the caller of WorkerPool), only after the
WaitGroup confirms all writers are done.

## Common mistakes the race detector catches

```go
// WRONG — shared counter, unprotected
var count int
go func() {
    for job := range jobs {
        count++          // DATA RACE: multiple goroutines write count
        results <- ...
    }
}()
```

```go
// WRONG — close races with last writer
go func() {
    wg.Wait()
    close(results)   // RACE: another goroutine may still be in `results <-`
}()
```

Both are flagged instantly by `go test -race` because the race detector
instruments every memory access and reports the exact goroutines + stack traces
involved.

## Production extensions

In production worker pools you almost always want:

**Context cancellation.** Add `ctx context.Context` and select between `jobs`
and `ctx.Done()` in each worker so the pool drains gracefully on shutdown.

**Error propagation.** Add an `errors chan error` or use `golang.org/x/sync/errgroup`,
which provides a WaitGroup that captures the first non-nil error and can cancel
a context on failure.

**Bounded result channel.** If the consumer is slower than the pool, a small
buffered `results` channel back-pressures the workers without blocking the
caller. An unbuffered channel here would deadlock if the caller isn't ranging
before calling WorkerPool.
