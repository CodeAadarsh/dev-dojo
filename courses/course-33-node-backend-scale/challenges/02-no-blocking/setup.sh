#!/usr/bin/env bash
# Plants the "Don't Block the Event Loop" starter project.
# Zero extra deps — pure Node.js.
# Idempotent — re-running overwrites source files but preserves node_modules.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/02-no-blocking"
mkdir -p "$WORK/src" "$WORK/test"

# ── package.json ──────────────────────────────────────────────────────────────
cat > "$WORK/package.json" << 'EOF'
{
  "name": "no-blocking",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "test": "node --test test/sample.test.js"
  },
  "devDependencies": {}
}
EOF

# ── src/compute.js — skeleton ─────────────────────────────────────────────────
cat > "$WORK/src/compute.js" << 'EOF'
// compute.js

// computeBlocking: correct synchronous implementation — do not change this.
// For n=500_000 it runs for ~1 ms on modern hardware and blocks the event loop.
export function computeBlocking(n) {
  let sum = 0
  for (let i = 1; i <= n; i++) sum += i
  return sum
}

// computeAsync: make this non-blocking.
//
// The current stub calls computeBlocking synchronously, which blocks the event
// loop for the entire duration. While it runs, no timer, no I/O callback, and
// no incoming HTTP request can be processed.
//
// Fix: restructure so the event loop gets at least one turn before the result
// is resolved. Two approaches are shown in the brief:
//   A. setImmediate-based chunking — split the loop, yield between chunks
//   B. worker_threads — offload to a separate thread entirely
//
// The test verifies BOTH correctness (same result as computeBlocking) AND that
// a setImmediate callback registered before computeAsync fires before it resolves.
export function computeAsync(n) {
  // BUG: blocks the event loop — computeBlocking runs synchronously here
  return Promise.resolve(computeBlocking(n))
}
EOF

# ── test/sample.test.js — visible sample test ─────────────────────────────────
cat > "$WORK/test/sample.test.js" << 'EOF'
// sample.test.js — correctness only; run: node --test test/sample.test.js
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { computeAsync } from '../src/compute.js'

// sum(1 + 2 + ... + 100) = 5050
test('computeAsync — small input returns correct sum', async () => {
  const result = await computeAsync(100)
  assert.strictEqual(result, 5050, `expected 5050, got ${result}`)
})
EOF

# ── print next steps ──────────────────────────────────────────────────────────
echo
echo "Work directory : $WORK"
echo
echo "Task           : implement computeAsync in src/compute.js so it returns"
echo "                 the same value as computeBlocking WITHOUT blocking the"
echo "                 event loop between calls."
echo
echo "Prerequisites  :"
echo "  cd $WORK && npm install   (nothing to install — zero deps)"
echo
echo "Run sample test: cd $WORK && npm test"
echo "Verify + flag  : bash courses/course-33-node-backend-scale/challenges/02-no-blocking/verify.sh"
