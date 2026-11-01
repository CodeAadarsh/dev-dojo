#!/usr/bin/env bash
# Verifier for "In-Memory Queue Worker".
# Plants the HIDDEN test suite, runs node --test, prints flag on all-pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/04-queue-worker"
FLAG='KUBE{bounded_concurrency_with_dead_letter}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]            || fail "work directory missing — run setup.sh first"
[ -f "$WORK/src/worker.js" ] || fail "src/worker.js not found — run setup.sh first"

cd "$WORK"
npm install --silent 2>/dev/null || npm install 2>&1 | tail -5

# ── write hidden test file ────────────────────────────────────────────────────
HIDDEN="$WORK/test/_verify_hidden.test.js"
cat > "$HIDDEN" << 'TESTEOF'
import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { Queue } from '../src/queue.js';
import { Worker } from '../src/worker.js';

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// ── helpers ──────────────────────────────────────────────────────────────────
function makeJob(id, opts = {}) {
  return {
    id,
    payload: {},
    attempts: 0,
    maxAttempts: opts.maxAttempts ?? 3,
    handler: opts.handler ?? (async () => {}),
  };
}

// ── test 1: happy path ────────────────────────────────────────────────────────
describe('happy path', () => {
  it('processes a successful job exactly once', async () => {
    const q = new Queue();
    let callCount = 0;
    const job = makeJob('happy-1', {
      handler: async () => { callCount++; },
    });
    q.enqueue(job);
    const w = new Worker(q, { concurrency: 2 });
    await w.start();
    assert.equal(callCount, 1, 'handler should be called exactly once');
    assert.ok(w.processed.has('happy-1'), 'id should be in processed');
    assert.equal(w.running, 0, 'no running slots should remain');
    assert.equal(w.deadLetter.length, 0, 'dead-letter should be empty');
  });
});

// ── test 2: idempotency ───────────────────────────────────────────────────────
describe('idempotency', () => {
  it('deduplicates jobs with the same id — handler called once', async () => {
    const q = new Queue();
    let callCount = 0;
    const handler = async () => { callCount++; };
    // enqueue the same id twice
    q.enqueue(makeJob('idem-1', { handler }));
    q.enqueue(makeJob('idem-1', { handler }));
    const w = new Worker(q, { concurrency: 2 });
    await w.start();
    assert.equal(callCount, 1, 'duplicate id must not cause double-processing');
    assert.ok(w.processed.has('idem-1'));
  });
});

// ── test 3: dead-letter after max attempts ────────────────────────────────────
describe('dead-letter', () => {
  it('retries then dead-letters a permanently failing job', async () => {
    const q = new Queue();
    let callCount = 0;
    const job = makeJob('fail-1', {
      maxAttempts: 3,
      handler: async () => { callCount++; throw new Error('always fails'); },
    });
    q.enqueue(job);
    const w = new Worker(q, { concurrency: 1 });
    await w.start();
    assert.equal(callCount, 3, 'should attempt exactly maxAttempts times');
    assert.equal(w.deadLetter.length, 1, 'job should be in dead-letter');
    assert.equal(w.deadLetter[0].id, 'fail-1');
    assert.equal(w.processed.size, 0, 'failed job must not appear in processed');
    assert.equal(w.running, 0);
  });
});

// ── test 4: backoff ───────────────────────────────────────────────────────────
describe('backoff', () => {
  it('waits at least attempts*100ms between retries', async () => {
    const q = new Queue();
    const times = [];
    let call = 0;
    const job = makeJob('back-1', {
      maxAttempts: 3,
      handler: async () => {
        times.push(Date.now());
        call++;
        if (call < 3) throw new Error('not yet');
      },
    });
    q.enqueue(job);
    const w = new Worker(q, { concurrency: 1 });
    await w.start();
    // Gap between attempt 0->1 should be >= 100ms, 1->2 >= 200ms
    assert.ok(times.length >= 2, 'must have at least 2 attempts');
    const gap1 = times[1] - times[0];
    assert.ok(gap1 >= 90, `gap between attempt 0 and 1 should be >=100ms, got ${gap1}ms`);
    if (times.length >= 3) {
      const gap2 = times[2] - times[1];
      assert.ok(gap2 >= 190, `gap between attempt 1 and 2 should be >=200ms, got ${gap2}ms`);
    }
    assert.ok(w.processed.has('back-1'), 'job that eventually succeeds should be in processed');
  });
});

// ── test 5: bounded concurrency ──────────────────────────────────────────────
describe('bounded concurrency', () => {
  it('never exceeds the concurrency limit', async () => {
    const q = new Queue();
    let peakRunning = 0;
    let currentRunning = 0;
    const LIMIT = 3;
    const NUM_JOBS = 10;
    for (let i = 0; i < NUM_JOBS; i++) {
      q.enqueue(makeJob(`conc-${i}`, {
        handler: async () => {
          currentRunning++;
          peakRunning = Math.max(peakRunning, currentRunning);
          await sleep(20);
          currentRunning--;
        },
      }));
    }
    const w = new Worker(q, { concurrency: LIMIT });
    await w.start();
    assert.ok(
      peakRunning <= LIMIT,
      `peak running ${peakRunning} exceeded concurrency limit ${LIMIT}`
    );
    assert.equal(w.processed.size, NUM_JOBS, 'all jobs should be processed');
    assert.equal(w.running, 0);
  });
});
TESTEOF

if node --test "$HIDDEN" 2>&1; then
  rm -f "$HIDDEN"
  echo
  echo "All checks passed. Submit this flag in the platform:"
  echo
  echo "    $FLAG"
else
  rm -f "$HIDDEN"
  fail "one or more checks failed — fix your implementation and retry"
fi
