# Don't Block the Event Loop

A p99 latency spike hits every midnight when the daily-report cron fires. Flame graph shows 100% time in a `for` loop — not I/O wait, not GC, just a hot loop chewing through 500 000 records. Every other in-flight request stalls for the full duration. The ticket: *"make the compute handler non-blocking so the health check endpoint keeps responding during report generation."*

## Context

`setup.sh` plants a zero-dependency Node.js project:

```
~/.kube-dojo-work/02-no-blocking/
├── package.json      # "type": "module", no extra deps
├── src/
│   └── compute.js    # computeBlocking (given) + computeAsync (stub — fix this)
└── test/
    └── sample.test.js  # one visible correctness test
```

`computeBlocking(n)` is provided and correct — do not change it. Your job is to make `computeAsync(n)` return the same value without blocking the event loop.

## Prerequisites

```bash
cd ~/.kube-dojo-work/02-no-blocking
npm install      # nothing to install — zero deps
```

## How the event loop works

Node.js is single-threaded. Your JS runs in one call stack. "Async" means *yielding* — breaking work into chunks and returning control to the event loop between them so it can process timers, I/O callbacks, and incoming requests.

```
┌─ call stack ──────────────┐        ┌─ event loop ──────────────────────┐
│  computeBlocking(500_000) │──blocks│  timers (setTimeout, setImmediate) │
│  ████████████████████████ │  loop  │  I/O callbacks                     │
│  ████████████████████████ │◄──────►│  incoming HTTP requests             │
└───────────────────────────┘        └───────────────────────────────────┘
```

While `computeBlocking` runs, the event loop cannot process anything. A `setTimeout(fn, 0)` queued before the compute fires only after the entire synchronous loop finishes.

## Mission

Implement `computeAsync(n)` in `src/compute.js` so the `node:test` harness passes both checks:

| Check | What it asserts |
|-------|-----------------|
| Correctness | `computeAsync(500_000)` returns `125_000_250_000` (same as `computeBlocking`) |
| Non-blocking | A `setImmediate` callback registered before calling `computeAsync` fires *before* `computeAsync` resolves — proving the loop was yielded |

The non-blocking check is deterministic: it tests *ordering*, not timing. If `computeAsync` calls `computeBlocking` synchronously (even for 0.1 ms), the microtask (`.then`) runs before the `setImmediate` macrotask and the ordering test fails.

### Approach A — setImmediate chunking (recommended)

Split the loop into chunks. After each chunk, call `setImmediate(step)` to yield. Other callbacks (health check handler, timers) run between chunks.

```js
export function computeAsync(n) {
  return new Promise((resolve) => {
    let sum = 0, i = 1
    const CHUNK = 50_000
    function step() {
      const end = Math.min(i + CHUNK - 1, n)
      for (; i <= end; i++) sum += i
      if (i > n) resolve(sum)
      else setImmediate(step)
    }
    step()
  })
}
```

### Approach B — Worker Thread (offload to another thread entirely)

```js
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads'
import { fileURLToPath } from 'node:url'

if (!isMainThread) {
  // This branch runs inside the worker thread
  let sum = 0
  for (let i = 1; i <= workerData; i++) sum += i
  parentPort.postMessage(sum)
}

export function computeAsync(n) {
  return new Promise((resolve, reject) => {
    const w = new Worker(new URL(import.meta.url), { workerData: n })
    w.on('message', resolve)
    w.on('error', reject)
  })
}
```

Both approaches pass the test. The setImmediate approach keeps everything single-threaded and is simpler. Worker threads are better when the chunk overhead is too high or when you truly need parallelism.

## Debugging

**Symptom:** correctness test passes but the non-blocking test fails.
**Cause:** `computeAsync` calls `computeBlocking(n)` synchronously before resolving — `return Promise.resolve(computeBlocking(n))` blocks just as badly as the synchronous version, because `computeBlocking` runs before the Promise is even created.
**Fix:** The computation must be *deferred*. `setImmediate(step)` or `new Worker(...)` both defer it past the current synchronous frame.

**Symptom:** setImmediate chunking is correct but slow on large n.
**Cause:** Chunk size is too small — every `setImmediate` call has overhead (~0.1 ms). At 10 chunks per millisecond, 10 000 chunks × 0.1 ms = 1 000 ms overhead.
**Fix:** Tune chunk size. For the test's n=500 000, a CHUNK of 50 000 means 10 yields — negligible overhead. Measure with `performance.now()` if needed.

**Symptom (Worker approach):** `Error: Cannot use import statement in a module` inside the worker.
**Cause:** Worker threads in ESM (`"type": "module"`) work fine but require the worker file URL to be an ESM file. Passing `import.meta.url` as the worker URL makes the same file run as both main thread and worker, controlled by `isMainThread`.
**Fix:** Use `new Worker(new URL(import.meta.url), ...)` with the `isMainThread` guard shown in Approach B.

> **War story.** A financial report endpoint at a previous project blocked the Node process for 800 ms per request during month-end closes — generating a PDF synchronously using a pure-JS library. Health check timeouts triggered autoscaler teardowns, which made things worse. Moving the PDF generation into a `node:worker_threads` Worker dropped p99 from 800 ms to 12 ms on the main thread (worker still took 800 ms, but the event loop was free). The load balancer stopped marking instances unhealthy. Zero code changes outside the one function.

## Verify

```bash
bash courses/course-33-node-backend-scale/challenges/02-no-blocking/verify.sh
```

Both checks green → flag printed.
