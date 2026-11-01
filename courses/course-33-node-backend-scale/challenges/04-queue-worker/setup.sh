#!/usr/bin/env bash
# Plants the "In-Memory Queue Worker" starter project.
# Idempotent — re-running overwrites source files but preserves node_modules.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/04-queue-worker"
mkdir -p "$WORK/src" "$WORK/test"

# ── package.json ─────────────────────────────────────────────────────────────
cat > "$WORK/package.json" << 'EOF'
{
  "name": "queue-worker",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "test": "node --test test/worker.test.js"
  },
  "devDependencies": {}
}
EOF

# ── src/queue.js — fully implemented ─────────────────────────────────────────
cat > "$WORK/src/queue.js" << 'EOF'
// In-memory FIFO queue.
// A Job is: { id: string, payload: any, attempts: number, maxAttempts: number, handler: async (job) => void }

export class Queue {
  #items = [];
  #seen = new Set(); // track enqueued ids for dedup at enqueue time (optional path)

  enqueue(job) {
    this.#items.push(job);
  }

  dequeue() {
    return this.#items.shift();
  }

  size() {
    return this.#items.length;
  }

  peek() {
    return this.#items[0];
  }
}
EOF

# ── src/worker.js — skeleton ─────────────────────────────────────────────────
cat > "$WORK/src/worker.js" << 'EOF'
// Worker skeleton.
// Implement the Worker class so the node --test harness passes.

export class Worker {
  /**
   * @param {import('./queue.js').Queue} queue
   * @param {{ concurrency: number }} options
   */
  constructor(queue, options = {}) {
    this.queue = queue;
    this.concurrency = options.concurrency ?? 1;

    /** Set<string> — ids of successfully processed jobs */
    this.processed = new Set();

    /** Array<object> — jobs that exhausted maxAttempts */
    this.deadLetter = [];

    /** number — currently running handler slots */
    this.running = 0;

    // TODO: add any internal state you need
  }

  /**
   * Drain the queue. Resolves when the queue is empty and all in-flight
   * handlers have settled.
   * @returns {Promise<void>}
   */
  async start() {
    // TODO: implement bounded-concurrency drain loop with:
    //   - idempotency: skip jobs whose id is already in this.processed
    //   - retry up to job.maxAttempts with backoff (attempts * 100 ms)
    //   - dead-letter after exhausting attempts
    throw new Error('not implemented');
  }
}
EOF

# ── test/worker.test.js — visible sample test ────────────────────────────────
cat > "$WORK/test/worker.test.js" << 'EOF'
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { Queue } from '../src/queue.js';
import { Worker } from '../src/worker.js';

// Helper: make a job that always succeeds
function successJob(id) {
  return { id, payload: {}, attempts: 0, maxAttempts: 3, handler: async () => {} };
}

// Helper: make a job that always throws
function alwaysFailJob(id) {
  return { id, payload: {}, attempts: 0, maxAttempts: 3, handler: async () => { throw new Error('boom'); } };
}

describe('Worker — sample tests (a subset of the full harness)', () => {
  it('processes a successful job', async () => {
    const q = new Queue();
    q.enqueue(successJob('j1'));
    const w = new Worker(q, { concurrency: 2 });
    await w.start();
    assert.ok(w.processed.has('j1'), 'j1 should be in processed');
    assert.equal(w.running, 0, 'no running slots should remain');
  });

  it('dead-letters a permanently failing job', async () => {
    const q = new Queue();
    q.enqueue(alwaysFailJob('f1'));
    const w = new Worker(q, { concurrency: 1 });
    await w.start();
    assert.equal(w.deadLetter.length, 1, 'one job should be dead-lettered');
    assert.equal(w.deadLetter[0].id, 'f1');
    assert.equal(w.running, 0);
  });
});
EOF

# ── print next steps ──────────────────────────────────────────────────────────
echo
echo "Work directory : $WORK"
echo
echo "Task           : implement src/worker.js so the node --test harness passes."
echo
echo "Prerequisites  :"
echo "  cd $WORK && npm install"
echo
echo "Run sample tests: cd $WORK && node --test test/worker.test.js"
echo "Verify + flag  : bash courses/course-33-node-backend-scale/challenges/04-queue-worker/verify.sh"
