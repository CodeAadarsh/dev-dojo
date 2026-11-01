#!/usr/bin/env bash
# Verifier for "Don't Block the Event Loop".
# Plants hidden tests, runs node --test, prints flag on all-pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/02-no-blocking"
FLAG='KUBE{event_loop_is_not_free}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]                || fail "work directory missing — run setup.sh first"
[ -f "$WORK/src/compute.js" ] || fail "src/compute.js not found — run setup.sh first"

cd "$WORK"
npm install --silent 2>/dev/null || true

# ── write hidden test file ────────────────────────────────────────────────────
HIDDEN="$WORK/test/_verify_hidden.test.js"
cat > "$HIDDEN" << 'TESTEOF'
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { computeAsync } from '../src/compute.js'

const N = 500_000
const EXPECTED = N * (N + 1) / 2   // 125_000_250_000

test('computeAsync returns the correct sum for n=500_000', async () => {
  const result = await computeAsync(N)
  assert.strictEqual(result, EXPECTED,
    `expected ${EXPECTED}, got ${result} — result must match computeBlocking(n)`)
})

// Deterministic ordering test — no timing thresholds involved.
//
// How it works:
//   1. Register a setImmediate callback (macrotask A) — order = []
//   2. Call computeAsync(N), attach .then (runs when promise resolves)
//   3. await Promise.all — event loop takes over
//
// BLOCKING stub: computeBlocking runs synchronously inside computeAsync before
//   the promise is created. The .then microtask fires before any macrotask.
//   order = ['compute', 'tick'] → assertion fails.
//
// NON-BLOCKING (setImmediate chunking): computeAsync queues setImmediate(step)
//   and returns a pending promise. Macrotask A (tick) fires first (FIFO queue).
//   order = ['tick', 'compute'] → assertion passes.
test('computeAsync does not block the event loop (ordering test)', async () => {
  const order = []

  const tickPromise = new Promise((resolve) => {
    setImmediate(() => {
      order.push('tick')
      resolve()
    })
  })

  const computePromise = computeAsync(N).then((result) => {
    order.push('compute')
    return result
  })

  const [result] = await Promise.all([computePromise, tickPromise])

  assert.strictEqual(
    order[0], 'tick',
    `setImmediate fired after computeAsync resolved — the event loop was blocked. ` +
    `order was: ${JSON.stringify(order)}. ` +
    `Use setImmediate-based chunking or worker_threads (see brief.md).`
  )
  assert.strictEqual(result, EXPECTED,
    `result check: expected ${EXPECTED}, got ${result}`)
})
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
