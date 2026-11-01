# Testing & Observability

> **Module 06 · Course 33** — A service that works on your laptop but catches you off guard in production is untested. A service that's failing silently and you don't know it is unobserved. These are two sides of the same problem: you don't have enough signal about what your code is actually doing. This module fixes that.

The goal is not 100% coverage for its own sake. It's a test suite that catches real regressions fast, and a production system that tells you exactly which request caused the problem without needing to reproduce it.

---

## Testing stack — picking the right tool

| Tool | Sweet spot | Why |
|------|-----------|-----|
| `node:test` | Library code, utility functions, algorithms | Zero deps, ships with Node 20+, fast startup, `--watch` mode, works with TypeScript via `tsx` |
| `vitest` | Full TypeScript project, needs snapshot, component, or browser tests | Native TS, Jest-compatible API, Vite-powered watch is fast, ecosystem momentum |
| `jest` | Legacy projects already using it | Stable but slowest cold start; no reason to start new projects on it |

The decision in 2025: **use `node:test` for anything that doesn't need a full framework** — it avoids the "which jest transform config breaks today" problem. Reach for `vitest` when you want snapshots, mocking with `vi.fn()`, or per-file browser environments. Don't use both in the same project.

```typescript
// node:test — no config file, no plugins
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

describe('validateEmail', () => {
  it('rejects addresses without a domain', () => {
    assert.equal(validateEmail('user@'), false);
  });

  it('accepts a well-formed address', () => {
    assert.equal(validateEmail('user@example.com'), true);
  });
});
```

Run with `node --test --require tsx/cjs` (or `tsx --test`) to handle TypeScript. No `ts-jest`, no Babel.

---

## Unit vs integration — drawing the line

A **unit test** runs the function in isolation. Everything it depends on is replaced with a double. Fast, deterministic, and brittle to refactoring.

An **integration test** wires up real components — a real database, a real HTTP server — and exercises the behavior from the boundary. Slower, but catches the category of bug where "each unit works but they don't talk correctly."

The ratio that tends to work for a Node REST service: **70% unit / 30% integration**. Don't invert this — if your integration tests take 10 minutes, developers stop running them.

```
unit tests          src/lib/*, pure functions, domain logic
integration tests   HTTP routes (supertest), database queries (real Turso/SQLite)
e2e tests           a full deployed environment; expensive; usually only in CI
```

---

## Test doubles — mock, stub, spy

Three terms that are often conflated:

- **Stub** — a replacement that returns canned data. Used to remove a dependency.
- **Mock** — a stub with assertions baked in. Fails the test if not called correctly.
- **Spy** — wraps the real implementation and records how it was called. Useful for side-effect verification without replacing behavior.

`node:test` has first-class support via `mock`:

```typescript
import { mock, describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';

import { sendWelcomeEmail } from '../src/email.js';
import * as mailer from '../src/mailer.js'; // the dep we'll stub

describe('sendWelcomeEmail', () => {
  beforeEach(() => mock.restoreAll());

  it('calls mailer.send with the right template', async () => {
    const spy = mock.method(mailer, 'send', async () => ({ messageId: 'test-123' }));

    await sendWelcomeEmail({ to: 'a@b.com', name: 'Alice' });

    assert.equal(spy.mock.callCount(), 1);
    const [arg] = spy.mock.calls[0].arguments;
    assert.equal(arg.template, 'welcome');
    assert.equal(arg.to, 'a@b.com');
  });
});
```

`mock.restoreAll()` in `beforeEach` is not optional — a spy left on a module method across tests is one of the primary causes of flaky test suites.

---

## HTTP integration tests with supertest

`supertest` starts your Express/Fastify app in-process and fires real HTTP requests without binding to a port. It's the right tool for route-level integration tests.

```typescript
import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import supertest from 'supertest';
import { buildApp } from '../src/app.js';
import { db } from '../src/db.js';

describe('POST /users', () => {
  let request: ReturnType<typeof supertest>;

  before(async () => {
    const app = await buildApp(); // create app; don't call app.listen()
    request = supertest(app);
    await db.migrate();          // run migrations against a test SQLite db
  });

  after(async () => {
    await db.destroy();
  });

  it('creates a user and returns 201', async () => {
    const res = await request
      .post('/users')
      .send({ email: 'new@example.com', name: 'Bob' })
      .expect(201);

    assert.ok(res.body.id);
    assert.equal(res.body.email, 'new@example.com');
  });

  it('returns 409 for a duplicate email', async () => {
    await request.post('/users').send({ email: 'dup@example.com', name: 'X' });
    await request.post('/users').send({ email: 'dup@example.com', name: 'Y' }).expect(409);
  });
});
```

Key points: `buildApp()` returns the app object without calling `.listen()`. `supertest(app)` starts an ephemeral server on a random port internally. The test database is real SQLite, not mocked — which means the constraint violation in the 409 test is real.

---

## Structured logging with pino

`console.log` in production is a tar pit. You can't query it, you can't filter by request ID, and the timestamp format is inconsistent. Use `pino`.

```typescript
import pino from 'pino';

export const logger = pino({
  level: process.env.LOG_LEVEL ?? 'info',
  // In development, pretty-print. In production, NDJSON.
  transport: process.env.NODE_ENV === 'development'
    ? { target: 'pino-pretty' }
    : undefined,
  redact: ['req.headers.authorization', 'body.password'], // never log these
});
```

**Child loggers** are the key pattern — they inherit the parent's level and transport, but carry extra bound fields:

```typescript
// In a request handler
const reqLogger = logger.child({ requestId: req.id, userId: req.user?.id });
reqLogger.info({ path: req.path }, 'request received');
// -> {"level":30,"time":1735689600000,"requestId":"abc123","userId":42,"path":"/items","msg":"request received"}
```

Every log line emitted from within that request carries `requestId` and `userId` without threading them through every function call. This is the difference between "search logs for this user" being a 10-second query and a 10-minute grep.

### Log levels

| Level | When |
|-------|------|
| `trace` | High-frequency internal events; disable in prod |
| `debug` | Developer context; enable per-service during incidents |
| `info` | Normal lifecycle events (request received, job started) |
| `warn` | Recoverable abnormal conditions (retry, fallback used) |
| `error` | Unrecoverable for this request; requires human attention |
| `fatal` | Process is about to exit |

Log at `info` by default in production. Set `LOG_LEVEL=debug` per pod during an incident investigation, not globally.

---

## Request IDs with AsyncLocalStorage

Passing a logger or request ID through every function argument is noisy. `AsyncLocalStorage` is the Node idiomatic solution — it's a context that propagates automatically through async call chains.

```typescript
import { AsyncLocalStorage } from 'node:async_hooks';
import { randomUUID } from 'node:crypto';

export const requestContext = new AsyncLocalStorage<{ requestId: string }>();

// In your HTTP framework middleware
app.use((req, _res, next) => {
  const requestId = req.headers['x-request-id'] as string ?? randomUUID();
  req.id = requestId;
  requestContext.run({ requestId }, next);
});

// Anywhere in the call chain — no argument threading
function getCurrentRequestId(): string | undefined {
  return requestContext.getStore()?.requestId;
}

// In a logger wrapper
export function log(level: pino.Level, msg: string, data?: object) {
  const ctx = requestContext.getStore();
  logger[level]({ requestId: ctx?.requestId, ...data }, msg);
}
```

This pattern means that a database query helper, a third-party SDK call, or a utility function buried three levels deep can all emit logs with the correct `requestId` — without the top-level handler having to pass it down.

> **Why not use a global `Map<correlationId, context>`?** Because async chains can interleave: two concurrent requests both running at the same tick would read the same global variable. `AsyncLocalStorage` is per-async-context — it follows the execution flow, not the wall clock.

---

## OpenTelemetry — traces and metrics

Logs tell you what happened. Traces tell you how long each piece took and where time was spent. Add both; they answer different questions.

```typescript
// src/telemetry.ts — run this before importing anything else
import { NodeSDK } from '@opentelemetry/sdk-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';

export const sdk = new NodeSDK({
  traceExporter: new OTLPTraceExporter({
    url: process.env.OTEL_EXPORTER_OTLP_ENDPOINT ?? 'http://localhost:4318/v1/traces',
  }),
  instrumentations: [getNodeAutoInstrumentations()],
});

sdk.start();

process.on('SIGTERM', async () => {
  await sdk.shutdown();
  process.exit(0);
});
```

Auto-instrumentation patches `http`, `net`, `dns`, Express/Fastify, `pg`, `mysql2`, `redis`, etc. without changing your application code. For custom spans:

```typescript
import { trace } from '@opentelemetry/api';

const tracer = trace.getTracer('my-service');

async function processJob(jobId: string) {
  return tracer.startActiveSpan(`job.process`, async (span) => {
    span.setAttribute('job.id', jobId);
    try {
      const result = await doWork(jobId);
      span.setAttribute('job.result', result.status);
      return result;
    } catch (err) {
      span.recordException(err as Error);
      span.setStatus({ code: SpanStatusCode.ERROR });
      throw err;
    } finally {
      span.end(); // always end; leaked spans cause memory growth
    }
  });
}
```

In a Kubernetes cluster, the standard setup is: each pod exports to a collector sidecar or a DaemonSet OTLP receiver, which forwards to Tempo/Jaeger/Zipkin. For the dojo, the LGTM stack (Loki + Grafana + Tempo + Mimir) is the target.

---

## Debugging Tests & Observability

### Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Tests pass locally, fail on CI 1 in 5 runs | State shared between tests — database rows, module-level singletons, un-restored mocks | Reset state in `afterEach`; call `mock.restoreAll()`; use a fresh DB per test file |
| `await someAsyncFn()` in a test never resolves or times out | Missing `await` on the assertion or the function itself; unhandled rejection swallowing the error | Add `--test-timeout=5000`; wrap in `try/catch assert.fail()` to surface the real error |
| Logs have no request IDs; impossible to trace a failure to a request | `AsyncLocalStorage` not wired up, or middleware runs after the logging middleware | Move the `requestContext.run()` call to be the first middleware |
| A 500 is returned but logs are empty | Exception caught by framework but error logging is inside a catch that itself throws, or `err.message` is logged but not `err.stack` | Log `{ err }` (the whole error object) — pino serialises the stack automatically |
| `supertest` tests hang indefinitely | App under test has a `setInterval` or open DB connection keeping the process alive | Call `app.close()` in `after()`; use `.unref()` on timers; close DB in teardown |
| OTel spans appear in traces but lack attributes | Span created but `.end()` never called after an early `return` | Put `span.end()` in a `finally` block; use `tracer.startActiveSpan` with callback form |

### Debugging flaky async tests

The pattern that catches most flakiness: run the suite in a tight loop on CI before merging:

```bash
# Run 10 times; fail fast on first red run
for i in $(seq 1 10); do node --test --require tsx/cjs src/**/*.test.ts || exit 1; done
```

If it's flaky on iteration 3 but not 1, you have shared state. Instrument:

```typescript
// Add to test setup — catches leaked timers and open handles
// node:test's --detect-open-handles is equivalent
process.on('exit', () => {
  const handles = (process as any)._getActiveHandles?.() ?? [];
  if (handles.length > 0) {
    console.error('open handles at exit:', handles.map((h: any) => h.constructor.name));
  }
});
```

> **War story.** A team I reviewed code for had a CI suite that was green 95% of the time but failed on the same three tests in a non-deterministic order. The root cause: the test file for the `UserService` was importing the real `sendWelcomeEmail` module (which used a module-level email client that connected on import), and that client's underlying TCP socket kept the event loop alive after the tests finished. The next test file's setup ran before the socket's `end` event fired, leaving the mock in a half-reset state. Fixing it was two lines: `afterAll(() => emailClient.close())` in the UserService test and `.unref()` on the client's internal `keepAliveTimer`. No more flakiness.

---

## Checkpoint

You're ready for the observability challenges when you can, without looking anything up:

1. Name one situation where `node:test` is the right choice over vitest and vice versa.
2. Write a `mock.method()` call that stubs a module export and verify it was called with specific arguments.
3. Explain what `supertest` does that `fetch('http://localhost:3000/...')` doesn't — specifically the port-binding difference.
4. Configure a `pino` logger that pretty-prints in development and emits NDJSON in production, and redacts one sensitive field.
5. Explain, without looking at code, what `AsyncLocalStorage` solves and why a `Map<requestId, context>` wouldn't work.
6. Name the three things a `startActiveSpan` block must always do when an error is thrown.
7. Diagnose why a `supertest` test hangs after the last assertion passes.

➡ Next up: **Performance & Scaling** — making the service fast enough that you need more than one copy of it, and deploying those copies safely.
