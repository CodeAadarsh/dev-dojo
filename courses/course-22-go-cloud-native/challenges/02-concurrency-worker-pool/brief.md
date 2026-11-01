# Bounded Worker Pool

Post-mortem excerpt from a production incident:

> *"The file-processing service started leaking goroutines under load. Root cause: each incoming request called `go processFile(...)` with no back-pressure. At peak, 40 000 goroutines were resident, each holding an open file descriptor. The OOM killer terminated the pod at 02:14 UTC. Fix: replace unbounded spawning with a bounded worker pool that caps goroutine count at N."*

Your job: implement `WorkerPool` in `pool.go` so the harness passes under `go test -race`.

## Context

`setup.sh` plants a starter module in your work directory:

```
~/.kube-dojo-work/02-concurrency-worker-pool/
├── go.mod
├── pool.go        # Job and Result types defined; WorkerPool stub
└── pool_test.go   # visible smoke test you can run locally
```

## Prerequisites

Go 1.22 or later. No external dependencies.

```bash
go version   # must be >= go1.22
```

## Mission

Implement `WorkerPool` in `pool.go`:

```go
func WorkerPool(n int, jobs <-chan Job, results chan<- Result, transform func(int) int)
```

The function **blocks** until every job is processed, then returns. The contract:

| Requirement | Detail |
|-------------|--------|
| Exactly N workers | Start exactly `n` goroutines — not 1, not N+1, not one-per-job |
| All jobs processed | Every `Job` sent on `jobs` produces exactly one `Result` on `results` |
| Correct output | `Result.Output = transform(Job.Input)`, `Result.JobID = Job.ID` |
| Channel closed | `results` is closed before `WorkerPool` returns — callers use `range results` |
| Race-free | `go test -race ./...` must pass with zero data-race reports |

The hidden verifier runs `go test -race ./...` with 100+ jobs across multiple worker counts. It will detect:
- Results channel never closed (test hangs on `range results`)
- Duplicate or missing job processing
- Any data race reported by the Go race detector

## Why it matters

Go makes it trivially easy to *start* a goroutine (`go f()`) and catastrophically
easy to forget to *bound* them. The canonical bounded-pool pattern is:

1. One `jobs` channel shared by all N workers (channels are safe to receive from
   concurrently — the runtime ensures exactly one goroutine gets each send).
2. A `sync.WaitGroup` counting exactly N goroutines; each worker does `defer
   wg.Done()`.
3. Close `results` **after** `wg.Wait()` — not inside a goroutine, not before
   all workers have exited.

The WaitGroup placement is the most common mistake: `close(results)` before
`wg.Wait()` is a race between the closer and the last worker still writing.

## Verify

```bash
bash courses/course-22-go-cloud-native/challenges/02-concurrency-worker-pool/verify.sh
```

Flag printed only when `go test -race ./...` exits 0.
