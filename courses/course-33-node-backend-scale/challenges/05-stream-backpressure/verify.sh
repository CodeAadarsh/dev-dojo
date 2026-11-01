#!/usr/bin/env bash
# Verifier for "Stream Backpressure".
# Plants a hidden test suite, runs node --test, prints flag on all-pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/05-stream-backpressure"
FLAG='KUBE{backpressure_saves_memory}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]               || fail "work directory missing — run setup.sh first"
[ -f "$WORK/src/transform.js" ] || fail "src/transform.js not found — run setup.sh first"

cd "$WORK"
npm install --silent 2>/dev/null || npm install 2>&1 | tail -5

HIDDEN="$WORK/test/_verify_hidden.test.js"
cat > "$HIDDEN" << 'TESTEOF'
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { processPipeline, UpperCaseTransform } from '../src/transform.js';

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// Slow readable: emits one item per tick to give sink time to fall behind
function makeSlowSource(n, itemDelayMs = 0) {
  let i = 0;
  return new Readable({
    objectMode: true,
    read() {
      if (i >= n) { this.push(null); return; }
      const chunk = { line: `line ${i}`, seq: i };
      i++;
      if (itemDelayMs > 0) {
        setTimeout(() => this.push(chunk), itemDelayMs);
      } else {
        this.push(chunk);
      }
    },
  });
}

// Error-emitting source
function makeErrorSource(failAt) {
  let i = 0;
  return new Readable({
    objectMode: true,
    read() {
      if (i >= failAt) {
        this.destroy(new Error(`source error at ${failAt}`));
        return;
      }
      this.push({ line: `line ${i}`, seq: i });
      i++;
    },
  });
}

// ── test 1: correctness ───────────────────────────────────────────────────────
describe('correctness', () => {
  it('upper-cases all lines and preserves seq', async () => {
    const n = 20;
    const src = makeSlowSource(n);
    const { results } = await processPipeline(src, 8);
    assert.equal(results.length, n, `expected ${n} results, got ${results.length}`);
    for (let i = 0; i < n; i++) {
      assert.equal(results[i].seq, i, `seq mismatch at index ${i}`);
      assert.equal(results[i].line, `LINE ${i}`, `line mismatch at index ${i}`);
    }
  });
});

// ── test 2: backpressure — peakBuffered <= hwm ────────────────────────────────
describe('backpressure', () => {
  it('peak buffered items stay within highWaterMark', async () => {
    const HWM = 4;
    const N = 50;
    // Fast source, slow sink: create pipeline with a slow writable to force backpressure
    // We measure peakBuffered from the return value
    const src = makeSlowSource(N);
    const { results, peakBuffered } = await processPipeline(src, HWM);
    assert.equal(results.length, N, 'all items should be processed');
    assert.ok(
      peakBuffered <= HWM + 2, // +2 tolerance for pipeline internals
      `peakBuffered ${peakBuffered} exceeded highWaterMark ${HWM} (with tolerance 2)`
    );
  });
});

// ── test 3: error propagation ─────────────────────────────────────────────────
describe('error propagation', () => {
  it('rejects when source emits an error', async () => {
    const src = makeErrorSource(5);
    await assert.rejects(
      () => processPipeline(src, 4),
      /source error/,
      'pipeline should reject when source errors'
    );
  });
});

// ── test 4: large dataset stays memory-safe ───────────────────────────────────
describe('memory safety', () => {
  it('processes 1000 items without peakBuffered exploding', async () => {
    const HWM = 4;
    const N = 1000;
    const src = makeSlowSource(N);
    const { results, peakBuffered } = await processPipeline(src, HWM);
    assert.equal(results.length, N);
    // peakBuffered should never approach N — backpressure should keep it small
    assert.ok(
      peakBuffered <= HWM * 4,
      `peakBuffered ${peakBuffered} too large for HWM ${HWM} — backpressure is broken`
    );
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
