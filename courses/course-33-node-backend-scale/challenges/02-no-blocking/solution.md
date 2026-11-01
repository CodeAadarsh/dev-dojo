# Solution — Don't Block the Event Loop

## Approach A: setImmediate chunking (recommended)

```js
// src/compute.js
export function computeBlocking(n) {
  let sum = 0
  for (let i = 1; i <= n; i++) sum += i
  return sum
}

export function computeAsync(n) {
  return new Promise((resolve) => {
    let sum = 0
    let i = 1
    const CHUNK = 50_000

    function step() {
      const end = Math.min(i + CHUNK - 1, n)
      for (; i <= end; i++) sum += i
      if (i > n) {
        resolve(sum)
      } else {
        setImmediate(step)
      }
    }

    step()
  })
}
```

## Approach B: Worker Thread

```js
// src/compute.js
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads'

export function computeBlocking(n) {
  let sum = 0
  for (let i = 1; i <= n; i++) sum += i
  return sum
}

if (!isMainThread) {
  // Runs inside the worker — blocking here doesn't affect the main event loop.
  parentPort.postMessage(computeBlocking(workerData))
}

export function computeAsync(n) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL(import.meta.url), { workerData: n })
    worker.on('message', resolve)
    worker.on('error', reject)
  })
}
```

## Why each design decision matters

**Why `Promise.resolve(computeBlocking(n))` still blocks.**
JavaScript evaluates function arguments before calling them. `computeBlocking(n)` is an argument to `Promise.resolve()`, so it runs synchronously — the loop completes before `Promise.resolve` is even called. Wrapping a synchronous call in a Promise does not make it asynchronous. The computation must be *deferred* past the current synchronous frame.

**Why `setImmediate` and not `setTimeout(fn, 0)`.**
Both work, but `setImmediate` fires in the *check* phase of the event loop, immediately after all I/O events in the current iteration. `setTimeout(fn, 0)` fires in the *timers* phase of the next iteration, which is slightly later and less deterministic. `setImmediate` is the canonical "yield to the event loop and come back immediately" tool in Node.js.

**Chunk size matters.**
Too small (e.g., CHUNK=1) and the setImmediate overhead dominates — ~500 000 yields × 0.1 ms overhead = 50 s. Too large and you block too long per chunk. A chunk that takes 5–10 ms is a good starting point for interactive responsiveness. For n=500 000, CHUNK=50 000 means 10 yields at ~0.1 ms each — 1 ms overhead total.

**Worker threads — when to use them.**
Worker threads give you true parallelism (separate V8 isolate, separate event loop, can use all CPU cores). They're the right choice when:
- The compute is long enough that even chunked setImmediate starves the main loop
- You want to use all CPU cores for throughput
- The compute cannot be easily chunked (e.g., native bindings, heavy FFT)

The trade-off: Worker creation has ~10 ms startup cost and data serialisation overhead. For a one-off report generation that takes 800 ms, that's fine. For a hot path called 10 000 times per second, use a pre-created Worker pool (the `piscina` library is the idiomatic choice).

**The ordering test — why it's deterministic.**
The test registers a `setImmediate` callback *before* calling `computeAsync`. If `computeAsync` defers work (via `setImmediate` or Worker), the earlier-registered setImmediate fires first (FIFO). If `computeAsync` runs synchronously, the `.then` microtask fires before the setImmediate macrotask — microtasks always drain before the next macrotask. This is a property of the JS engine's event loop, not wall-clock timing, so it holds on every machine at every speed.

## Attacker's view / hardening preview

A blocked event loop is also a Denial-of-Service vector. A malicious client can send a request body crafted to trigger worst-case regex backtracking (ReDoS), a slow JSON parse, or a deliberately large CSV that forces a synchronous parsing path. The fix is the same: push heavy work off the main thread. `worker_threads` with a bounded pool + a request queue protects against both accidental and adversarial blocking. Rate-limiting at the ingress level (nginx, Envoy) buys time but doesn't eliminate the risk.

## Apply and verify

```bash
cd ~/.kube-dojo-work/02-no-blocking
# Replace src/compute.js with Approach A or B above, then:
node --test test/sample.test.js
bash courses/course-33-node-backend-scale/challenges/02-no-blocking/verify.sh
```
