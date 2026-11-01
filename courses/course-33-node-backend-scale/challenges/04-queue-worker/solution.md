# Solution — In-Memory Queue Worker

Complete implementation of `src/worker.js`. Key design decisions explained after the code.

```js
// src/worker.js
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

export class Worker {
  constructor(queue, options = {}) {
    this.queue = queue;
    this.concurrency = options.concurrency ?? 1;
    this.processed = new Set();
    this.deadLetter = [];
    this.running = 0;
    this._inflight = new Set(); // Promise handles for active slots
  }

  async start() {
    const slots = [];

    const runNext = async () => {
      while (true) {
        // Wait until concurrency slot available
        if (this.running >= this.concurrency) {
          // Yield to let a running slot finish
          await Promise.race([...this._inflight]);
        }

        const job = this.queue.dequeue();
        if (!job) break;

        // Idempotency: skip duplicates
        if (this.processed.has(job.id)) continue;

        this.running++;
        const p = this._processJob(job).finally(() => {
          this.running--;
          this._inflight.delete(p);
        });
        this._inflight.add(p);
        // Don't await — let it run concurrently, but don't launch more than limit
      }
      // Drain all remaining inflight
      while (this._inflight.size > 0) {
        await Promise.race([...this._inflight]);
      }
    };

    await runNext();
  }

  async _processJob(job) {
    let attempt = 0;
    while (attempt < job.maxAttempts) {
      if (attempt > 0) {
        // Backoff: attempt * 100ms before retry
        await sleep(attempt * 100);
      }
      try {
        job.attempts = attempt;
        await job.handler(job);
        this.processed.add(job.id);
        return;
      } catch {
        attempt++;
      }
    }
    // Exhausted all attempts
    this.deadLetter.push({ ...job, attempts: job.maxAttempts });
  }
}
```

## Why each design decision is required

**Bounded concurrency via `this.running` counter + `Promise.race`.**
The naive approach is `await Promise.all(jobs.map(...))` — which parallelizes everything. Instead, track `this.running` and only launch a new slot when `running < concurrency`. When the pool is full, `await Promise.race([...this._inflight])` yields until *one* slot frees. This is a semaphore implemented with Promises — the same pattern used by `p-limit` and production queue libraries.

**Idempotency via `this.processed.has(job.id)` before dispatch.**
Check *before* launching, not inside the handler. If the handler ran once and succeeded, the id is in `this.processed`. When the same id arrives again (webhook retry, at-least-once bus) the worker skips it without touching the handler. This is the dedup-at-ingestion pattern; handler-level idempotency (e.g., INSERT OR IGNORE in a DB) is a second layer, not a substitute.

**Retry counter starts at 0, backoff is `attempt * 100ms`.**
Attempt 0 is the first try — no sleep. Attempt 1 sleeps 100 ms. Attempt 2 sleeps 200 ms. This is linear backoff; exponential would be `2^attempt * base`. Linear is sufficient for the test harness and predictable in timing assertions. Production systems typically use exponential with jitter.

**Dead-letter after `maxAttempts`, not `maxAttempts + 1`.**
The loop runs `while (attempt < maxAttempts)` — attempts 0, 1, 2 for `maxAttempts: 3`. After the loop, push to `deadLetter`. Common off-by-one: using `<=` gives `maxAttempts + 1` calls, which fails the `callCount === 3` assertion.

**`finally` block decrements `running` and removes from `_inflight`.**
If you decrement only on success or only on failure, a throwing handler leaks a slot. `finally` runs regardless of outcome. The same pattern applies to connection pool management, semaphores, and any "resource in use" counter.

## Attacker's view / hardening preview

An in-memory queue loses all jobs on process crash. For production resilience:
- Back the queue with Redis (BullMQ, Upstash Queue) or a durable message bus (Kafka, SQS).
- Store job state in a DB; the worker becomes an idempotent consumer of persisted events.
- Dead-lettered jobs should trigger an alert (PagerDuty, Slack) — a silent dead-letter queue is a data loss event in disguise.
- Expose `worker.processed.size`, `worker.deadLetter.length`, and `worker.running` to a metrics endpoint — these are the three dials on-call cares about.

## Apply and verify

```bash
# Replace src/worker.js with the solution above, then:
cd ~/.kube-dojo-work/04-queue-worker
node --test test/worker.test.js
bash courses/course-33-node-backend-scale/challenges/04-queue-worker/verify.sh
```
