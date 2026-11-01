# The Event Loop & Async Patterns

> **Module 02 · Course 33** — Node.js runs your code on a single thread. One slow synchronous operation — a 200 ms JSON transform, an unbounded loop, a naïve Fibonacci call — blocks *every* concurrent request until it finishes. You already use `async/await`. This module goes deeper: what the event loop actually does between `await`s, why a blocked loop is the hardest kind of latency to diagnose, and the async patterns that prevent it.

---

## The event loop: what actually runs between requests

Node.js is built on [libuv](https://libuv.org), which implements an event loop. The loop spins continuously, checking for I/O completions, timers, and other events. Each iteration processes one "turn" before moving to the next.

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Node.js event loop phases                       │
│                                                                     │
│   ┌──────────┐    ┌──────────────┐    ┌─────────┐    ┌──────────┐  │
│   │  timers  │───▶│  I/O events  │───▶│  check  │───▶│  close   │  │
│   │(setTimeout│   │(fs, net, etc)│    │(setImm- │    │ callbacks│  │
│   │setInterval│   │  callbacks   │    │  ediate)│    │          │  │
│   └──────────┘    └──────────────┘    └─────────┘    └──────────┘  │
│         │                                                  │        │
│         └──────────────────────────────────────────────────┘        │
│                              ▲                                      │
│              between every phase: drain the microtask queue         │
│              (Promise.then, queueMicrotask, process.nextTick)       │
└─────────────────────────────────────────────────────────────────────┘
```

The critical distinction is between **macrotasks** (one per loop iteration at most) and **microtasks** (all of them, before any macrotask or phase transition):

```ts
// Execution order demonstration
setTimeout(() => console.log('A: setTimeout'), 0);      // macrotask

Promise.resolve().then(() => console.log('B: Promise')); // microtask

process.nextTick(() => console.log('C: nextTick'));      // microtask (higher priority)

console.log('D: synchronous');

// Output:
// D: synchronous
// C: nextTick
// B: Promise
// A: setTimeout
```

`process.nextTick` fires before other microtasks. Resolved Promises fire before `setTimeout(fn, 0)`. This order is guaranteed.

```ts
// setImmediate fires in the "check" phase, after I/O
setImmediate(() => console.log('setImmediate'));
setTimeout(() => console.log('setTimeout 0ms'), 0);

// From a fresh script: order is non-deterministic (depends on startup timing)
// From inside an I/O callback: setImmediate always fires first
fs.readFile('/etc/hostname', () => {
  setTimeout(() => console.log('timeout inside I/O'), 0);
  setImmediate(() => console.log('immediate inside I/O'));
  // immediate always prints first here — it's the next phase in the loop
});
```

This matters in practice when you are controlling the order of operations in tests or when you need to defer work until after the current I/O event has fully processed.

---

## What "blocking the loop" really means

Your entire HTTP server — every request, every response — runs on the event loop thread. Any synchronous work that takes longer than a few milliseconds delays every other request until it completes:

```ts
// This blocks the loop for the entire duration of the compute
app.get('/digest', (req, res) => {
  let result = 0;
  for (let i = 0; i < 1_000_000_000; i++) {
    result += Math.sqrt(i); // 100–200 ms on a modern CPU
  }
  res.json({ result });
});

// While that loop runs, no other request is processed.
// Every concurrent client waits behind it.
```

Other common blockers:
- `JSON.parse` on a large payload (> 1 MB)
- Synchronous file reads (`fs.readFileSync`) in a hot path
- `bcrypt.hashSync` (intentionally slow by design — use the async version)
- `crypto.pbkdf2Sync` with high iteration counts
- Regular expressions with catastrophic backtracking

Measure whether you actually have a problem before optimising:

```bash
# clinic.js bubbleprof — visualises async activity and gaps
npx clinic bubbleprof -- node server.js

# Node.js built-in performance hooks — measure a specific section
import { performance, PerformanceObserver } from 'node:perf_hooks';

performance.mark('start');
doHeavyWork();
performance.mark('end');
performance.measure('heavy-work', 'start', 'end');

const obs = new PerformanceObserver((list) => {
  for (const entry of list.getEntries()) {
    console.log(`${entry.name}: ${entry.duration.toFixed(2)}ms`);
  }
});
obs.observe({ type: 'measure' });
```

---

## Worker threads for CPU-bound work

The right fix for CPU-bound work is to move it off the event loop thread into a **worker thread**. Worker threads share the process address space but run on a separate OS thread, so they cannot block the loop:

```ts
// worker.ts — runs in the worker thread
import { parentPort, workerData } from 'node:worker_threads';

function computeDigest(n: number): number {
  let result = 0;
  for (let i = 0; i < n; i++) result += Math.sqrt(i);
  return result;
}

// Send the result back to the main thread
parentPort?.postMessage(computeDigest(workerData.iterations));
```

```ts
// main.ts — event loop thread
import { Worker } from 'node:worker_threads';
import path from 'node:path';

function runInWorker(iterations: number): Promise<number> {
  return new Promise((resolve, reject) => {
    const worker = new Worker(path.resolve('./worker.js'), {
      workerData: { iterations },
    });
    worker.on('message', resolve);
    worker.on('error', reject);
    worker.on('exit', (code) => {
      if (code !== 0) reject(new Error(`Worker exited with code ${code}`));
    });
  });
}

app.get('/digest', async (req, res) => {
  // event loop is free while the worker computes
  const result = await runInWorker(1_000_000_000);
  res.json({ result });
});
```

> **Worker pool.** Creating a new `Worker` per request is expensive (~3–5 ms startup plus memory). For a service that does CPU work on every request, maintain a fixed-size pool. The [`piscina`](https://github.com/piscinajs/piscina) library implements exactly this pattern and is the production choice.

---

## Promises and async/await pitfalls

`async/await` makes asynchronous code look synchronous, which is mostly good. But it hides a few common mistakes.

### Sequential await in a loop

```ts
// BAD: requests are made one at a time — each waits for the previous
async function fetchUsersSequential(ids: string[]) {
  const users = [];
  for (const id of ids) {
    users.push(await fetchUser(id)); // serialised — n round trips
  }
  return users;
}
// Time: sum of all individual request durations

// GOOD: all requests in flight simultaneously
async function fetchUsersConcurrent(ids: string[]) {
  return Promise.all(ids.map((id) => fetchUser(id)));
}
// Time: duration of the slowest single request
```

### Swallowing errors

```ts
// This error disappears silently — the Promise rejects, but nothing catches it
async function processOrder(id: string) {
  const order = await getOrder(id);
  updateMetrics(order);  // async function — not awaited, rejection is lost
}

// Fix: await it, or explicitly handle the fire-and-forget case
async function processOrder(id: string) {
  const order = await getOrder(id);
  // If you genuinely don't care about the result, log failures:
  updateMetrics(order).catch((err) => logger.error('metrics update failed', err));
}
```

### Missing error handling with `Promise.all`

```ts
// If any single fetch rejects, Promise.all rejects immediately
// and the other in-flight requests are abandoned (not cancelled)
const [userA, userB, userC] = await Promise.all([
  fetchUser('a'),  // if this throws, userB and userC results are lost
  fetchUser('b'),
  fetchUser('c'),
]);

// Use Promise.allSettled when you need all results, even if some fail
const results = await Promise.allSettled([
  fetchUser('a'),
  fetchUser('b'),
  fetchUser('c'),
]);

for (const result of results) {
  if (result.status === 'fulfilled') {
    process(result.value);
  } else {
    logger.warn('fetch failed', result.reason);
  }
}
```

### `Promise.race` and `Promise.any`

```ts
// Promise.race: resolves/rejects with the FIRST settled promise (either way)
// Use for timeouts:
const withTimeout = <T>(promise: Promise<T>, ms: number): Promise<T> =>
  Promise.race([
    promise,
    new Promise<T>((_, reject) =>
      setTimeout(() => reject(new Error(`timeout after ${ms}ms`)), ms),
    ),
  ]);

// Promise.any: resolves with the FIRST fulfilled promise; rejects only if ALL fail
// Use for redundant sources:
const data = await Promise.any([
  fetchFromRegionA(id),
  fetchFromRegionB(id),
]); // whichever responds first wins
```

---

## AbortController: cooperative cancellation

Node.js 15+ ships `AbortController` and `AbortSignal`. Pass a signal through async operations to allow cooperative cancellation:

```ts
app.get('/slow-report', async (req, res) => {
  const controller = new AbortController();

  // Cancel the downstream work if the client disconnects
  req.on('close', () => controller.abort());

  try {
    const data = await fetchLargeDataset({ signal: controller.signal });
    const report = await buildReport(data, { signal: controller.signal });
    res.json(report);
  } catch (err) {
    if ((err as Error).name === 'AbortError') {
      // Client disconnected — stop processing, don't log as error
      return;
    }
    throw err;
  }
});

// Propagate the signal through fetch:
async function fetchLargeDataset({ signal }: { signal: AbortSignal }) {
  const res = await fetch('https://internal-data-api/export', { signal });
  return res.json();
}

// Use it with a timeout:
const controller = new AbortController();
const timeoutId = setTimeout(() => controller.abort(), 5000);
try {
  await doWork({ signal: controller.signal });
} finally {
  clearTimeout(timeoutId);
}
```

> **Cancellation is cooperative.** `abort()` signals intent — it does not forcibly kill the operation. Every async step in the chain must receive and respect the signal. If `buildReport` ignores it, the work continues after the client disconnects. Pass the signal to every I/O call and check `signal.aborted` at expensive synchronous checkpoints.

---

## Streams: handling data that doesn't fit in memory

Streams let you process data chunk-by-chunk instead of loading the entire payload first. The key concept is **backpressure**: the readable side should slow down when the writable side can't keep up.

```ts
import { createReadStream, createWriteStream } from 'node:fs';
import { createGzip } from 'node:zlib';
import { pipeline } from 'node:stream/promises';

// pipeline manages backpressure and error handling automatically
// it cleans up all streams on error, unlike manual .pipe() chaining
async function compressFile(input: string, output: string) {
  await pipeline(
    createReadStream(input),
    createGzip(),
    createWriteStream(output),
  );
}

// Streaming a large DB result to HTTP response — never loads the full result set
app.get('/export/users', async (req, res) => {
  res.setHeader('Content-Type', 'application/x-ndjson');
  const cursor = db.select().from(users).stream(); // Drizzle/Kysely cursor
  for await (const row of cursor) {
    const ok = res.write(JSON.stringify(row) + '\n');
    if (!ok) {
      // backpressure: the HTTP socket's write buffer is full
      await new Promise((resolve) => res.once('drain', resolve));
    }
  }
  res.end();
});
```

For HTTP request bodies over a few KB, avoid `express.json()` with its default 100kb limit or a custom large limit. Instead, stream and parse incrementally:

```ts
import { pipeline } from 'node:stream/promises';
import { createGunzip } from 'node:zlib';

app.post('/ingest', async (req, res) => {
  let processed = 0;
  await pipeline(
    req,                                          // incoming HTTP body as stream
    async function* (source) {
      let buffer = '';
      for await (const chunk of source) {
        buffer += chunk.toString();
        const lines = buffer.split('\n');
        buffer = lines.pop()!;                    // keep the incomplete last line
        for (const line of lines) {
          if (line.trim()) {
            yield JSON.parse(line);
          }
        }
      }
    },
    async function* (records) {
      for await (const record of records) {
        await insertRecord(record);
        processed++;
        yield;
      }
    },
  );
  res.json({ processed });
});
```

---

## Debugging async problems

### Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| p99 latency spikes; CPU 100%; p50 is fine | CPU-bound work on the event loop thread | Move to worker thread; measure first with `--prof` or clinic.js |
| Response time correlates with concurrent requests even on I/O-bound work | Multiple sequential `await`s where `Promise.all` should be used | Profile with clinic bubbleprof; restructure to concurrent awaits |
| Process exits with `UnhandledPromiseRejection` | `async` function called without `await`; `.then()` without `.catch()` | Enable `--unhandled-rejections=throw` (Node 15+ default); lint with `no-floating-promises` |
| Memory grows without bound under load | Promise storm — too many concurrent Promises creating closures | Limit concurrency; use `p-limit` or a semaphore; monitor `process.memoryUsage()` |
| Requests hang after client disconnect, work continues indefinitely | AbortSignal not threaded through downstream calls | Pass signal to every `fetch`, DB query, and check `signal.aborted` in loops |
| `setImmediate` or `process.nextTick` callback runs at unexpected time | Misunderstanding microtask vs macrotask order | Log phase order; read event loop spec; use `performance.mark` to instrument |

### Diagnosing a blocked event loop

The Node.js inspector is the best tool for this. Start the process with `--inspect` and open `chrome://inspect`:

```bash
node --inspect server.js
# or attach to a running process:
kill -USR1 <pid>  # enables inspector on a running Node process
```

For production-like profiling without a debugger, generate a V8 CPU profile:

```bash
node --prof server.js
# run some load while it's running, then:
node --prof-process isolate-*.log > profile.txt
# look for "Bottleneck" sections — they show which functions consumed the most time
```

`clinic.js` provides a higher-level view:

```bash
npx clinic doctor -- node server.js
# generates an HTML report pointing to potential issues
# "Event Loop Blocked" is the explicit warning you're looking for
```

### Diagnosing an unhandled rejection

Node 15+ treats unhandled rejections as fatal errors by default. Before that version, they were silent warnings. The pattern to catch the source:

```ts
// Add this at process startup in development to surface the stack trace
process.on('unhandledRejection', (reason, promise) => {
  console.error('Unhandled rejection at:', promise);
  console.error('Reason:', reason);
  // In production, report to your error tracker instead of logging
});

// ESLint rule to catch these statically:
// "@typescript-eslint/no-floating-promises": "error"
// This catches: someAsyncFn() without await or .catch()
```

### Diagnosing a Promise storm

When a request triggers hundreds or thousands of Promises concurrently (e.g. `Promise.all` over a large array), memory usage spikes because each Promise closure holds references:

```ts
// BAD: sends 10,000 HTTP requests simultaneously
const results = await Promise.all(ids.map((id) => fetchUser(id)));

// GOOD: process at most 10 concurrently
import pLimit from 'p-limit';
const limit = pLimit(10);
const results = await Promise.all(ids.map((id) => limit(() => fetchUser(id))));
```

Monitor memory during load tests: `process.memoryUsage().heapUsed`. A steady climb that doesn't level off is the signal.

> **War story.** I was profiling a report-generation endpoint that was 400 ms on my laptop but 4–5 seconds under light load in staging. The response time was proportional to concurrent users, not request complexity — a classic event loop blockage signature. `clinic doctor` flagged it in two minutes: a `JSON.stringify` call on the full aggregated result set (40–60 MB per request) was blocking the loop for the entire serialisation duration. The fix was switching to `fast-json-stringify` (which uses a pre-compiled schema to skip the object traversal overhead) and stream-writing the response in chunks. The endpoint dropped from 5 seconds to 280 ms at the same concurrency. The insight: `JSON.stringify` is not cheap on large objects, and no amount of async I/O code matters if you block synchronously while assembling the final response.

---

## Checkpoint

You are ready for the challenges when you can, without looking anything up:

1. Describe the order in which `process.nextTick`, `Promise.resolve().then()`, and `setTimeout(fn, 0)` callbacks fire, and explain why.
2. Identify whether a given request handler could block the event loop — list three operations that look harmless but aren't.
3. Rewrite a `for...of` loop with sequential `await` to use `Promise.all`, and explain when `Promise.allSettled` is the better choice.
4. Write a helper that wraps any Promise with a timeout using `Promise.race` and `AbortController`.
5. Use `pipeline` from `node:stream/promises` to pipe a file read through gzip compression to a response — and explain why `pipeline` is better than `.pipe()` for error handling.
6. Name two tools that measure event loop lag in production and one that profiles at development time.
7. Explain what a "Promise storm" is, how to detect one using `process.memoryUsage()`, and how `p-limit` solves it.

➡ Next up: **Data Access with Drizzle/Prisma** — schema as code, N+1 queries (the silent killer), connection pooling, and the one migration workflow that won't destroy your production database.
