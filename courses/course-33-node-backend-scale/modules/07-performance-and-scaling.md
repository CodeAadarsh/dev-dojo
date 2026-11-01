# Performance & Scaling

> **Module 07 · Course 33** — Node is single-threaded. For I/O-bound work that's usually fine. For CPU-bound work it's a liability. For anything at scale, it's the thing you work around — with clustering, worker threads, careful connection management, and a deployment that doesn't drop requests when you roll out a fix. This module covers each.

Intermediate Node devs know Node is single-threaded. Advanced ones know exactly when that bites you, how to measure it, and how to fix it without making the architecture complicated.

---

## The event loop and why one core isn't always enough

Node processes one JavaScript operation at a time on the main thread. I/O (network, disk) is non-blocking because libuv offloads it to a thread pool and wakes the event loop when results are ready. But any computation that stays on the main thread blocks everything else for its duration.

```
                    Event Loop (single JS thread)
                    ┌─────────────────────────────┐
  ─ timers ─────►  │  process setTimeout/Intervals │
  ─ pending I/O ►  │  process I/O callbacks        │
  ─ poll ───────►  │  wait for new I/O events       │
  ─ check ──────►  │  process setImmediate          │
  ─ close ──────►  │  cleanup callbacks             │
                    └─────────────────────────────┘
                    ↑
          any synchronous code BLOCKS all of this
```

The classic failure mode: a `JSON.parse` of a 50 MB payload, an unoptimised sort, a regex with catastrophic backtracking. While that runs, every other in-flight request waits. Measure it:

```typescript
// Naive event-loop lag detector — log whenever a 100ms setImmediate fires late
function monitorEventLoopLag(warnThresholdMs = 50) {
  let last = Date.now();
  const check = () => {
    const lag = Date.now() - last - 100;
    if (lag > warnThresholdMs) {
      console.warn({ event: 'event_loop_lag_ms', lag });
    }
    last = Date.now();
    setTimeout(check, 100).unref();
  };
  setTimeout(check, 100).unref();
}
```

For production, the `perf_hooks` `monitorEventLoopDelay` histogram is more accurate:

```typescript
import { monitorEventLoopDelay } from 'node:perf_hooks';

const histogram = monitorEventLoopDelay({ resolution: 10 });
histogram.enable();

setInterval(() => {
  const p99Ms = histogram.percentile(99) / 1e6; // nanoseconds → ms
  logger.info({ event_loop_p99_ms: p99Ms });
  histogram.reset();
}, 30_000).unref();
```

---

## Clustering — one process per core

`cluster` is Node's built-in way to fork multiple worker processes on the same port. The primary process dispatches connections round-robin to workers; workers share no memory with each other.

```typescript
// src/server.ts
import cluster from 'node:cluster';
import os from 'node:os';
import { startWorker } from './app.js';

const WORKERS = Number(process.env.WEB_CONCURRENCY ?? os.availableParallelism());

if (cluster.isPrimary) {
  for (let i = 0; i < WORKERS; i++) cluster.fork();

  cluster.on('exit', (worker, code, signal) => {
    console.error({ event: 'worker_exit', pid: worker.process.pid, code, signal });
    if (!worker.exitedAfterDisconnect) {
      // Unexpected crash — replace immediately
      cluster.fork();
    }
  });
} else {
  startWorker(); // each worker calls app.listen()
}
```

In Kubernetes you typically run **one process per pod** with `WEB_CONCURRENCY=1` and use pod replicas for horizontal scale — the orchestrator's restart and health-check semantics work better with single-process pods. Use clustering on raw VMs or on Heroku-style platforms where you can't control replica count.

> Setting `WEB_CONCURRENCY` from the environment lets ops tune it per deployment without a code change.

---

## Worker threads — CPU work off the main thread

`worker_threads` runs JavaScript in a true OS thread. Unlike cluster (separate processes), workers share the same memory space via `SharedArrayBuffer` and can pass zero-copy `ArrayBuffer`s using transferables.

Use workers for: image resizing, PDF generation, JSON schema validation of large payloads, cryptographic operations, anything where `htop` shows one CPU core at 100%.

```typescript
// src/workers/compress.worker.ts
import { parentPort, workerData } from 'node:worker_threads';
import { deflateSync } from 'node:zlib';

const input = workerData as Buffer;
const compressed = deflateSync(input);
parentPort!.postMessage(compressed, [compressed.buffer]); // transferable — zero copy
```

```typescript
// src/compress.ts — main thread side
import { Worker } from 'node:worker_threads';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const WORKER_PATH = path.join(path.dirname(fileURLToPath(import.meta.url)), 'workers/compress.worker.js');

export function compressAsync(data: Buffer): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const worker = new Worker(WORKER_PATH, { workerData: data });
    worker.on('message', (result: Buffer) => resolve(result));
    worker.on('error', reject);
  });
}
```

For sustained throughput, maintain a worker pool rather than creating a new worker per request. `piscina` is the production-quality pool implementation:

```typescript
import Piscina from 'piscina';

const pool = new Piscina({
  filename: WORKER_PATH,
  maxThreads: os.availableParallelism() - 1, // leave one core for I/O
});

export const compressAsync = (data: Buffer) => pool.run(data);
```

---

## Caching — the fastest request is the one you don't make

Three layers, in order of speed:

```
1. In-process LRU          zero network latency, lost on restart, per-process
2. Redis / Upstash         shared across pods, survives restarts, ~1 ms latency
3. HTTP cache headers      CDN or client caches the response; zero backend load
```

```typescript
import { LRUCache } from 'lru-cache';

// In-process: good for read-heavy, infrequently-changing reference data
const cache = new LRUCache<string, object>({
  max: 500,                   // max 500 items
  ttl: 60_000,                // 60s TTL
  allowStale: false,
});

async function getProduct(id: string): Promise<Product> {
  const cached = cache.get(id);
  if (cached) return cached as Product;

  const product = await db.query.products.findFirst({ where: eq(products.id, id) });
  if (!product) throw new NotFoundError(id);

  cache.set(id, product);
  return product;
}
```

For data that must be consistent across pods (user sessions, rate-limit counters), use a shared store. Upstash Redis is the free-tier choice for this stack:

```typescript
import { Redis } from '@upstash/redis';

const redis = new Redis({
  url: process.env.UPSTASH_REDIS_REST_URL!,
  token: process.env.UPSTASH_REDIS_REST_TOKEN!,
});

// Cache-aside pattern
async function getCachedUser(id: string): Promise<User> {
  const key = `user:${id}`;
  const hit = await redis.get<User>(key);
  if (hit) return hit;

  const user = await db.query.users.findFirst({ where: eq(users.id, id) });
  if (!user) throw new NotFoundError(id);

  await redis.setex(key, 300, JSON.stringify(user)); // 5 min TTL
  return user;
}
```

**HTTP cache headers** are the highest-leverage cache for public read APIs:

```typescript
res.setHeader('Cache-Control', 'public, max-age=60, stale-while-revalidate=300');
```

`stale-while-revalidate` tells a CDN: serve the stale version immediately while fetching a fresh one in the background. Response time stays <1 ms even when the cache is expiring.

---

## Keep-alive & connection reuse

Every `http.request()` or `fetch()` that uses the default agent creates a new TCP connection. At 100 rps calling a downstream service, that's 100 new TCP handshakes per second — latency and file-descriptor pressure.

```typescript
// WRONG — default agent creates a new connection per request
const res = await fetch('https://api.example.com/data');

// CORRECT — undici Pool reuses connections
import { Pool } from 'undici';

const apiPool = new Pool('https://api.example.com', {
  connections: 10,
  keepAliveTimeout: 30_000,
  keepAliveMaxTimeout: 300_000,
});

const { body } = await apiPool.request({ path: '/data', method: 'GET' });
const data = await body.json();
```

Create the pool once at startup and reuse it. A pool per downstream service, not a new one per request. The `connections` parameter is the maximum concurrent connections to that host.

For Node's built-in `http`: set `agent: new http.Agent({ keepAlive: true, maxSockets: 50 })` on your `http.request` calls. `undici` is faster than the built-in client for new code.

---

## Graceful shutdown — the most underrated topic in Node

Without a graceful shutdown, deploying a fix drops in-flight requests. Kubernetes sends `SIGTERM`, waits `terminationGracePeriodSeconds`, then `SIGKILL`. Your job is to finish open requests during that window.

```typescript
// src/shutdown.ts
export function registerGracefulShutdown(server: http.Server, db: DrizzleDB) {
  let isShuttingDown = false;

  const shutdown = async (signal: string) => {
    if (isShuttingDown) return;
    isShuttingDown = true;
    logger.info({ signal }, 'shutdown initiated');

    // 1. Stop accepting new connections
    server.close(async () => {
      logger.info('HTTP server closed');

      // 2. Wait for in-flight requests (server.close waits for them)
      // 3. Close downstream connections
      await db.client.close();
      logger.info('DB connection closed');

      process.exit(0);
    });

    // 4. Force-exit after grace period
    setTimeout(() => {
      logger.error('forced exit after grace period');
      process.exit(1);
    }, 25_000).unref(); // slightly less than terminationGracePeriodSeconds
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}
```

The K8s side of this is the `preStop` hook — it runs before the container receives `SIGTERM` and gives the load balancer time to remove the pod from its rotation before traffic stops:

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sh", "-c", "sleep 5"]
terminationGracePeriodSeconds: 30
```

Without the `preStop` sleep, the load balancer may still route requests to the pod for a few seconds after `SIGTERM` arrives — those requests get a connection refused. The 5s sleep ensures the pod is drained from rotation before shutdown starts.

---

## Horizontal scaling and statelessness

Horizontal scaling means running multiple identical pods and load-balancing across them. This only works if the service is **stateless** — no request can depend on which pod handles it.

Things that break statelessness:
- In-memory session state (use a shared store like Redis)
- Local file uploads (use object storage — S3/Cloudflare R2)
- In-process caches that must be consistent (use Redis or accept eventual consistency per-pod)
- Sticky WebSocket connections without coordination (use a pub/sub layer)

Test statelessness by running two pods and routing the same logical session through both. If the second pod doesn't work, you have stateful code.

---

## Packaging and deploying to Kubernetes

A minimal multi-stage Dockerfile for a Node service:

```dockerfile
FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:22-alpine AS builder
WORKDIR /app
COPY . .
RUN npm ci && npm run build   # tsc or esbuild

FROM node:22-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
COPY --from=deps /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY package.json .
EXPOSE 3000
USER node
CMD ["node", "dist/server.js"]
```

Pair it with a `.dockerignore` that excludes `node_modules`, `.env*`, `*.test.ts`, and build artifacts not needed at runtime. The image should be under 200 MB.

Kubernetes Deployment with probes and resource limits:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: dojo-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: api:1.0.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 3000
          env:
            - name: NODE_ENV
              value: production
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          livenessProbe:
            httpGet:
              path: /healthz
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /readyz
              port: 3000
            initialDelaySeconds: 3
            periodSeconds: 5
          lifecycle:
            preStop:
              exec:
                command: ["sh", "-c", "sleep 5"]
      terminationGracePeriodSeconds: 30
```

`/healthz` answers 200 always as long as the process is alive. `/readyz` answers 200 only when the service is ready to accept traffic (DB connected, caches warm). Kubernetes won't route traffic to a pod until readiness passes — never return 200 from readiness until you're actually ready.

---

## Debugging Performance & Scaling

### Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| p99 latency is 10× p50; one CPU core at 100% in `htop` | CPU-bound work blocking the event loop | Move work to a worker thread or piscina pool; measure with `monitorEventLoopDelay` |
| RSS grows 10–20 MB/hour, never reclaimed; OOM after days | Memory leak — objects accumulating in a `Map`, `Set`, or closure; unbounded LRU cache | Take two heap snapshots 30 min apart and diff them in Chrome DevTools; look for growing retained objects |
| Pods restart with exit code 137 every few hours | Container hitting memory `limit` — often caused by the same leak above | Verify with `kubectl describe pod <name>` → `OOMKilled`; then fix the leak or raise `limit` temporarily |
| Requests dropped for 2–5s on every rolling deployment | No `preStop` hook; load balancer still routing to terminating pod | Add `preStop: sleep 5`; verify with `curl` loop during a deploy |
| `kubectl get pods` shows pod stuck `Terminating` for minutes | Shutdown handler not exiting (open file descriptor or unconsumed stream keeping process alive) | Add `setTimeout(..., 25_000).unref()` force-exit in shutdown; check for `.unref()`-less timers |
| `fetch()` calls to downstream services have p99 > 500ms | New TCP connection per request — no connection pooling | Replace default `fetch` with an `undici.Pool`; check with `ss -tn | grep ESTABLISHED` in the pod |
| Service works on one pod but fails when two pods are running | Stateful code — in-memory session or cache that isn't shared | Identify the shared state; move to Redis or redesign as stateless |

### Taking a heap snapshot

```bash
# Start the process with --inspect (or add to the Deployment env for debugging)
node --inspect=0.0.0.0:9229 dist/server.js

# Port-forward from the pod
kubectl port-forward pod/<name> 9229:9229

# Open Chrome DevTools → about://inspect → take two snapshots 30 min apart
# Diff them: filter "Objects allocated between snapshots"
# Sort by "Retained Size" descending — that's your leak
```

For a faster answer in production without Chrome, `node --heap-prof` writes a V8 heap profile to a file on exit:

```typescript
// Triggered via HTTP endpoint for live services
import v8 from 'node:v8';

app.get('/debug/heap-snapshot', (_req, res) => {
  if (process.env.NODE_ENV !== 'production') {
    const path = v8.writeHeapSnapshot();
    res.send({ path });
  } else {
    res.status(403).send();
  }
});
```

> **War story.** An internal API service at SAP was leaking ~15 MB/hour. It had been restarting every ~48 hours ("just a container restartPolicy: Always thing") and nobody had looked closely at the log showing `OOMKilled`. When we took a heap snapshot diff, the largest retained set was ~40,000 instances of an object called `AbortController` — each one held by a `Map<requestId, AbortController>` that was populated on every incoming request but whose cleanup path only ran for *completed* requests, not for requests that the client abandoned mid-flight. A disconnect event on the socket was supposed to call `cleanup(requestId)` but the handler was registered on `req` after the middleware that populated the map, so for connections that dropped during auth (before the handler was attached), the controller leaked. The fix was registering the cleanup handler before populating the map. The leak went to zero immediately.

---

## Checkpoint

You're ready for the scaling challenges when you can, without looking anything up:

1. Name three categories of work that block the event loop and explain why `await` alone doesn't help with them.
2. Write the `cluster.on('exit')` handler that replaces a crashed worker but does not fork on graceful shutdown.
3. Explain why `piscina` is preferable to creating a new `Worker` per request.
4. Describe the three-layer caching hierarchy and give one example workload appropriate for each layer.
5. Explain what `terminationGracePeriodSeconds`, `preStop`, and `server.close()` each do, and why all three are required for zero-downtime deploys.
6. Name the difference between a liveness probe and a readiness probe — and describe a scenario where the readiness probe fails but the liveness probe passes.
7. Given a heap snapshot diff showing 40,000 growing `EventEmitter` objects, name the first two places you'd look in the code.

➡ That's the end of the module sequence. The remaining challenges in this course apply all seven modules to a single service that you'll build, harden, and deploy to the dojo cluster.
