# In-Memory Queue Worker

During an on-call shift you inherit a Node service that processes background jobs by just calling `Promise.all(jobs.map(run))`. Under any burst it saturates the DB connection pool, retries hammer a flaky downstream endpoint in a tight loop, and duplicate events (webhook retries, at-least-once message bus) cause double-charges. The ticket reads: *"rewrite the worker so it respects a concurrency limit, backs off on failure, deduplicates by job id, and sends permanently-failing jobs to a dead-letter queue."*

## Context

`setup.sh` plants a project in your work directory:

```
~/.kube-dojo-work/04-queue-worker/
├── package.json        # pinned deps, "type": "module"
├── src/
│   ├── queue.js        # Queue class + Job type — fully implemented
│   └── worker.js       # Worker skeleton — implement this
└── test/
    └── worker.test.js  # visible sample test (subset of the hidden harness)
```

The `Queue` class in `src/queue.js` is a simple in-memory FIFO with `enqueue(job)`, `dequeue()`, and `size()`. A `Job` is a plain object `{ id, payload, attempts, maxAttempts, handler }`.

## Prerequisites

```bash
cd ~/.kube-dojo-work/04-queue-worker
npm install
```

## Mission

Implement `src/worker.js` — specifically the `Worker` class — so it passes the full `node --test` harness.

### The `Worker` API your implementation must satisfy

```js
import { Worker } from './src/worker.js';

const worker = new Worker(queue, { concurrency: 3 });
await worker.start();    // drain the queue to empty
```

The `Worker` constructor receives the queue and an options object with at least `{ concurrency }`.

`worker.start()` returns a Promise that resolves when the queue is fully drained (all jobs processed or dead-lettered).

### What `verify.sh` checks

| Assertion | Why it matters |
|-----------|----------------|
| A job whose `handler` always succeeds is processed exactly once | Base case — the happy path must work |
| A job with the same `id` enqueued twice is processed exactly once | Idempotency — dedup by `id` before processing |
| A job whose `handler` always throws is retried up to `maxAttempts` times, then moved to `worker.deadLetter` | Retry loop — don't lose the job, but don't retry forever |
| Between retries, the worker waits at least `attempts * 100 ms` (exponential/linear backoff) | Backoff — a retrying worker that hammers instantly is worse than no retry |
| At no point do more than `concurrency` handlers run in parallel | Bounded concurrency — the whole point of the worker |

After `worker.start()` resolves:
- `worker.processed` — Set of job ids that completed successfully
- `worker.deadLetter` — Array of jobs that exhausted their attempts
- `worker.running` — must be 0 (no leaks)

## Debugging the worker

**Symptom:** `worker.running` never reaches 0 / `start()` never resolves.  
**Cause:** A handler promise was awaited but an unhandled rejection escaped the retry loop, leaving an inflight slot permanently occupied.  
**Fix:** Wrap every `handler(job)` call in a `try/catch` inside a self-contained async slot function. Resolve the slot promise in `finally`, not after `await handler`.

**Symptom:** Concurrency limit is exceeded in the test.  
**Cause:** You `await` each job before launching the next one — that serialises everything.  
**Fix:** Maintain a counter (`this.running`) and a Promise pool. When `running < concurrency`, launch a new slot without awaiting it. The `start()` loop should `await` only when the pool is full.

**Symptom:** A job that fails on attempt 1 is retried immediately with no delay, causing the timing assertion to fail.  
**Cause:** The backoff sleep is missing or placed after the handler re-enqueue instead of before the retry.  
**Fix:** `await sleep(job.attempts * 100)` **before** calling `handler` on a retried job (attempts > 0), or after catching the failure and before re-enqueuing.

> **War story.** The worst production bug I debugged was a worker that "worked in tests" but caused cascade failures in prod. The tests always resolved because they used `Promise.all` — which hid the concurrency problem entirely. The real cluster had a 50-connection DB pool; 300 concurrent workers saturated it in 200 ms. Adding a semaphore dropped p99 latency from 4 s to 80 ms on the first deploy. The concurrency limit is not a nice-to-have.

## Verify

```bash
bash courses/course-33-node-backend-scale/challenges/04-queue-worker/verify.sh
```

All assertions green → flag printed.
