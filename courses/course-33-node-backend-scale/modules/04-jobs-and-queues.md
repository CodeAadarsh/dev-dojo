# Background Jobs & Queues

> **Module 04 · Course 33** — HTTP is a request/response protocol. The client waits. Some work — sending a transactional email, resizing uploaded images, generating a PDF report, syncing to a third-party CRM — should not happen while a user is staring at a spinner. This module covers the architecture of reliable background job processing: durable queues, workers with bounded concurrency, retry/backoff, idempotency, and the graceful-shutdown contract your workers must satisfy before Kubernetes kills the process.

---

## Why offload work

The naive approach blocks the HTTP response on every downstream operation:

```
Client ──POST /orders──▶ HTTP handler
                              │
                              ├── insert order to DB (fast, ~5ms)
                              ├── send confirmation email (slow, ~400ms)
                              ├── notify warehouse API (slow, ~200ms)
                              ├── update analytics (slow, ~150ms)
                              │
                         ◀─── 200 OK (total: ~755ms)
```

Problems: p99 is dominated by the slowest downstream; any downstream failure fails the request; email providers have rate limits that manifest as request latency.

With a queue:

```
Client ──POST /orders──▶ HTTP handler
                              │
                              ├── insert order to DB (5ms)
                              ├── enqueue job: 'order.created' (2ms, Redis write)
                              │
                         ◀─── 201 Created (total: ~7ms)

                    [separately, any time]
Worker ──picks up job──▶ send email  (retries on failure, no user impact)
                    ──▶ notify warehouse
                    ──▶ update analytics
```

The HTTP response is fast because it does minimal work. The heavy lifting happens out-of-band, with full retry and monitoring support.

---

## BullMQ architecture

[BullMQ](https://docs.bullmq.io) is a battle-tested Node.js job queue backed by Redis. Redis is used as durable storage for job state — jobs survive process restarts.

```
┌──────────────────────────────────────────────────────────────────┐
│                      BullMQ architecture                         │
│                                                                  │
│  Producer (HTTP handler)          Redis                          │
│  ┌──────────────────────┐         ┌─────────────────────────┐   │
│  │  queue.add('job', {  │────────▶│  waiting list            │   │
│  │    orderId: '...'    │         │  active list             │   │
│  │  })                  │         │  completed list          │   │
│  └──────────────────────┘         │  failed list             │   │
│                                   │  delayed set (sorted)    │   │
│  Worker (separate process/pod)    └─────────────────────────┘   │
│  ┌──────────────────────┐                 │                      │
│  │  new Worker(queue,   │◀────────────────┘                     │
│  │    async (job) => {  │  BRPOPLPUSH (atomic dequeue)          │
│  │      process(job)    │                                        │
│  │    })                │                                        │
│  └──────────────────────┘                                        │
└──────────────────────────────────────────────────────────────────┘
```

BullMQ uses Redis sorted sets and lists to implement atomic job transitions. When a worker picks up a job, it moves from `waiting` to `active` — if the worker dies mid-processing, BullMQ's stall detection moves it back to `waiting` after a configurable lock duration.

### Basic producer setup

```ts
import { Queue } from 'bullmq';
import IORedis from 'ioredis';

const connection = new IORedis(process.env.REDIS_URL, {
  maxRetriesPerRequest: null, // required by BullMQ
});

const emailQueue = new Queue('emails', { connection });
const reportQueue = new Queue('reports', { connection });

// Add a job — returns immediately (Redis write ~1ms)
await emailQueue.add(
  'order-confirmation',
  { orderId: order.id, userEmail: user.email },
  {
    attempts: 5,
    backoff: { type: 'exponential', delay: 2000 },
    removeOnComplete: { count: 1000 }, // keep last 1000 completed jobs for inspection
    removeOnFail: { count: 500 },
  },
);

// Delayed job — run 1 hour from now
await emailQueue.add(
  'cart-abandonment-reminder',
  { userId: user.id },
  { delay: 60 * 60 * 1000 },
);
```

---

## Workers and concurrency

A worker polls the queue and processes jobs. The `concurrency` setting controls how many jobs run simultaneously per worker process:

```ts
import { Worker, Job } from 'bullmq';

const worker = new Worker(
  'emails',
  async (job: Job) => {
    switch (job.name) {
      case 'order-confirmation':
        await sendOrderConfirmation(job.data.orderId, job.data.userEmail);
        break;
      case 'cart-abandonment-reminder':
        await sendAbandonmentReminder(job.data.userId);
        break;
      default:
        throw new Error(`Unknown job type: ${job.name}`);
    }
  },
  {
    connection,
    concurrency: 5, // process up to 5 jobs simultaneously in this worker
    limiter: {
      max: 10,     // rate limit: max 10 jobs per second across all workers
      duration: 1000,
    },
  },
);

worker.on('completed', (job) => {
  console.log(`Job ${job.id} (${job.name}) completed`);
});

worker.on('failed', (job, err) => {
  console.error(`Job ${job?.id} failed:`, err.message);
});
```

> **Concurrency is per-worker-process.** If you have 3 worker pods with `concurrency: 5`, you have 15 concurrent job executions. Set concurrency based on your job's resource profile: I/O-bound jobs (HTTP calls, DB queries) can be high (10–50); CPU-bound jobs should be at most `os.cpus().length - 1`.

---

## Retries and exponential backoff

Every job that can fail transiently (network call, third-party API, rate limit) should have retry logic. The key is **exponential backoff** — waiting longer between each attempt to avoid hammering a struggling service:

```ts
// Retry schedule with exponential backoff (base 2 seconds):
// Attempt 1 fails → wait 2s
// Attempt 2 fails → wait 4s
// Attempt 3 fails → wait 8s
// Attempt 4 fails → wait 16s
// Attempt 5 fails → move to failed list (dead letter)

await queue.add('send-webhook', payload, {
  attempts: 5,
  backoff: {
    type: 'exponential',
    delay: 2000, // base delay in ms
  },
});

// Inside the worker, throw to trigger a retry (BullMQ retries on any uncaught throw)
async function processWebhook(job: Job) {
  const res = await fetch(job.data.url, {
    method: 'POST',
    body: JSON.stringify(job.data.payload),
  });

  if (res.status === 429) {
    // Rate limited — signal BullMQ to back off
    const retryAfter = parseInt(res.headers.get('retry-after') ?? '60', 10);
    throw Object.assign(new Error('Rate limited'), { retryAfter: retryAfter * 1000 });
  }

  if (!res.ok) {
    throw new Error(`Webhook failed: ${res.status} ${await res.text()}`);
  }
}
```

You can inspect attempt counts inside the handler:

```ts
async function handler(job: Job) {
  console.log(`Attempt ${job.attemptsMade + 1} of ${job.opts.attempts}`);
  // Use attemptsMade to implement custom logic:
  // e.g. escalate to a Slack alert only on the last attempt
  if (job.attemptsMade >= (job.opts.attempts ?? 1) - 1) {
    await alertOps(`Job ${job.id} is on its last attempt`);
  }
}
```

---

## Idempotency: at-least-once delivery is the guarantee

BullMQ guarantees **at-least-once delivery**, not exactly-once. After a worker crash, BullMQ will re-deliver a job it was processing. Your handler will run the same job twice.

**Idempotency** means running a job twice produces the same result as running it once. Design for it:

```ts
// BAD: charging twice is worse than not charging
async function processPayment(job: Job) {
  const charge = await stripe.paymentIntents.create({
    amount: job.data.amountCents,
    currency: 'inr',
    customer: job.data.customerId,
  });
  await db.insert(schema.payments).values({ stripeId: charge.id, ...job.data });
}

// GOOD: use idempotency key — Stripe deduplicates; DB unique constraint catches duplicates
async function processPayment(job: Job) {
  const idempotencyKey = `payment-${job.id}`; // job.id is stable across retries

  const charge = await stripe.paymentIntents.create(
    {
      amount: job.data.amountCents,
      currency: 'inr',
      customer: job.data.customerId,
    },
    { idempotencyKey }, // Stripe returns the same PaymentIntent for the same key
  );

  // ON CONFLICT DO NOTHING — safe to run twice
  await db
    .insert(schema.payments)
    .values({ stripeId: charge.id, orderId: job.data.orderId })
    .onConflictDoNothing();
}
```

General idempotency patterns:
1. Use `job.id` as the idempotency key for external API calls.
2. Use `INSERT ... ON CONFLICT DO NOTHING` or `ON CONFLICT DO UPDATE` for database writes.
3. Check "already done" at the start: `if (await isAlreadyProcessed(job.id)) return;`

---

## Dead-letter queue

Jobs that exhaust all retry attempts move to BullMQ's `failed` list. This is your dead-letter queue. Set up a monitor:

```ts
import { QueueEvents } from 'bullmq';

const queueEvents = new QueueEvents('emails', { connection });

queueEvents.on('failed', async ({ jobId, failedReason }) => {
  const job = await Job.fromId(emailQueue, jobId);
  if (!job) return;

  // Log full context for debugging
  logger.error('Job permanently failed', {
    jobId,
    jobName: job.name,
    data: job.data,
    attempts: job.attemptsMade,
    reason: failedReason,
    stacktrace: job.stacktrace,
  });

  // Alert if this is a critical job type
  if (job.name === 'order-confirmation') {
    await pagerDuty.createIncident(`Order email failed permanently: ${job.data.orderId}`);
  }
});

// Manual retry from dead-letter — for when you've fixed the underlying bug
const failedJobs = await emailQueue.getFailed(0, 100);
for (const job of failedJobs) {
  await job.retry(); // re-queues with the same data
}
```

---

## Scheduling: delayed and repeating jobs

```ts
import { Queue } from 'bullmq';

// Delayed job — send a follow-up email 3 days after sign-up
await emailQueue.add(
  'onboarding-followup',
  { userId: newUser.id },
  { delay: 3 * 24 * 60 * 60 * 1000 },
);

// Repeating job — cron syntax; runs at midnight IST (UTC+5:30)
await reportQueue.add(
  'daily-revenue-report',
  { reportDate: 'auto' }, // worker fills this in from new Date()
  {
    repeat: {
      pattern: '30 18 * * *', // 18:30 UTC = 00:00 IST
      tz: 'Asia/Kolkata',
    },
  },
);

// List all repeating jobs
const repeatableJobs = await reportQueue.getRepeatableJobs();
console.log(repeatableJobs);

// Remove a repeating job
await reportQueue.removeRepeatableByKey(repeatableJobs[0].key);
```

> **Idempotency matters for scheduled jobs too.** A `daily-revenue-report` job that runs twice because a deploy happened at midnight should produce the same report, not two conflicting inserts. Use `INSERT ... ON CONFLICT DO UPDATE` with the report date as the unique key.

---

## Graceful shutdown

Kubernetes sends `SIGTERM` before killing a process. Without a graceful shutdown handler, any job actively processing when the signal arrives is interrupted mid-execution and will be re-delivered — running twice. With a graceful shutdown, you complete the current job and stop accepting new ones:

```ts
const worker = new Worker('emails', processJob, { connection, concurrency: 5 });

async function shutdown() {
  console.log('Shutdown signal received. Draining worker...');

  // Stop accepting new jobs immediately
  // Wait for currently-running jobs to complete (up to 30 seconds)
  await worker.close();

  // Close the Redis connection
  await connection.quit();

  console.log('Worker shut down cleanly');
  process.exit(0);
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);  // Ctrl+C in dev
```

In Kubernetes, pair this with a `terminationGracePeriodSeconds` large enough for your longest expected job:

```yaml
spec:
  terminationGracePeriodSeconds: 60  # must be > your worker's drain timeout
  containers:
    - name: email-worker
      lifecycle:
        preStop:
          exec:
            command: ["sleep", "5"]  # give kube-proxy time to drain connections first
```

> **The 30-second rule:** BullMQ's default lock duration for an active job is 30 seconds. If your worker's `close()` waits longer than that, BullMQ assumes the job is stalled and re-delivers it to another worker. Either set `lockDuration` to match your expected max job duration, or ensure `close()` times out before the lock expires.

---

## Debugging jobs and queues

### Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Same side-effect happens twice (duplicate email, double charge) | Job ran twice due to worker crash during processing | Add idempotency key to every external call; use `ON CONFLICT DO NOTHING` in DB writes |
| Job retries forever and never reaches `failed` | `attempts` not set or set to `Infinity`; error is swallowed (empty catch) | Set a finite `attempts`; never silence errors in job handlers — always re-throw or let BullMQ see the throw |
| Jobs disappear on deploy (Redis data lost) | Using Redis without persistence — data is in-memory only | Enable Redis `AOF` or `RDB` persistence; use a managed Redis with persistence (Upstash, ElastiCache) |
| Worker memory grows over time | Concurrency too high + each job opens unclosed DB connections / streams | Profile with `--inspect`; ensure every resource opened in a job handler is closed before returning |
| Worker processed 0 jobs for 10 minutes but queue is non-empty | Worker crashed silently; connection lost | Monitor `worker.isRunning()`; add `worker.on('error')` handler; use a process supervisor or Kubernetes restart policy |
| Cron job runs twice at the scheduled time | Two worker instances both registered the repeating job | Register cron jobs from exactly one place (a dedicated scheduler process or an init job), not from every worker replica |

### Diagnosing duplicate processing

The diagnostic is a database audit trail. Add a `job_runs` table:

```ts
// At the start of every job handler:
async function processJob(job: Job) {
  const runId = `${job.id}-${job.attemptsMade}`;

  await db
    .insert(schema.jobRuns)
    .values({ runId, jobId: job.id, jobName: job.name, startedAt: new Date() })
    .onConflictDoNothing();

  // If the insert was a no-op (conflict), we've already processed this attempt
  const existing = await db.query.jobRuns.findFirst({
    where: eq(schema.jobRuns.runId, runId),
  });
  if (!existing) return; // already processed this exact attempt

  // ... actual job logic
}
```

### Diagnosing a poison job

A poison job is one that always fails — every retry fails, it fills the dead-letter queue, and its retries consume queue throughput. The pattern:

```bash
# BullMQ Bull Board — a UI for inspecting queue state
npm install @bull-board/express @bull-board/api

# Or from the CLI (Redis commands):
redis-cli LLEN bull:emails:failed    # how many failed jobs
redis-cli LRANGE bull:emails:failed 0 4 | xargs -I{} redis-cli HGET {} stacktrace
```

Always log `job.stacktrace` and `job.data` when a job enters the failed list. The data reveals if the job was invalid from the start (bad input) or if it was a transient failure that became permanent (infrastructure outage during all retry windows).

> **War story.** A report generation worker started silently disappearing jobs — they were added to the queue, the worker picked them up, but the `completed` count never incremented and the jobs were gone from both `active` and `failed`. After attaching `--inspect` to the worker process we found the issue: the job handler was calling an async function with `await` inside a `.forEach()` callback. `.forEach()` ignores returned Promises. The async operations ran, but the outer `async (job) => {...}` function resolved immediately (before any I/O completed), BullMQ marked the job complete, and all the actual database writes happened in detached Promises — some succeeded, some failed silently. The fix was replacing `.forEach()` with a `for...of` loop, which awaits each iteration. Lost jobs in a queue with no errors in the logs are almost always a detached Promise.

---

## Checkpoint

You are ready for the challenges when you can, without looking anything up:

1. Explain the difference between synchronous request handling and queue-based background processing — name two operations that should never happen inline in an HTTP handler.
2. Write a BullMQ producer that enqueues an `order.created` job with 5 retry attempts and exponential backoff starting at 2 seconds.
3. Write a BullMQ worker with `concurrency: 3` that handles two job types and logs on completion and failure.
4. Explain why "at-least-once delivery" means your job handler **must** be idempotent — and demonstrate using `job.id` as a Stripe idempotency key.
5. Implement a `SIGTERM` graceful shutdown handler that drains the worker before exiting, and explain what happens to an in-progress job without one.
6. Describe the "poison job" pattern — a job that always fails — and explain how to detect one using the dead-letter queue and BullMQ's `QueueEvents`.
7. Explain why registering a cron job from every worker replica causes duplicate execution — and where it should be registered instead.
8. Name the Redis persistence options that prevent job loss on Redis restart and explain the tradeoff between AOF and RDB.

➡ Next up: the challenges in this course — start with the type-safe API and job processor exercises to put these patterns into a running Node.js project the verifier can grade.
