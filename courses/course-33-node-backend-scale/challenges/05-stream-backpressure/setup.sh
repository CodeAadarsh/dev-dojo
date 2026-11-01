#!/usr/bin/env bash
# Plants the "Stream Backpressure" starter project.
# Idempotent — re-running overwrites source files but preserves node_modules.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/05-stream-backpressure"
mkdir -p "$WORK/src" "$WORK/test"

# ── package.json ─────────────────────────────────────────────────────────────
cat > "$WORK/package.json" << 'EOF'
{
  "name": "stream-backpressure",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "test": "node --test test/backpressure.test.js"
  },
  "devDependencies": {}
}
EOF

# ── src/transform.js — skeleton ───────────────────────────────────────────────
cat > "$WORK/src/transform.js" << 'EOF'
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { Readable, Writable } from 'node:stream';

/**
 * Object-mode Transform that upper-cases the `line` field of each chunk.
 *
 * Input chunk:  { line: string, seq: number }
 * Output chunk: { line: string (upper-cased), seq: number }
 *
 * @param {{ highWaterMark?: number }} options
 */
export class UpperCaseTransform extends Transform {
  constructor(options = {}) {
    super({
      objectMode: true,
      highWaterMark: options.highWaterMark ?? 4,
      ...options,
    });
    // TODO: track peakBuffered here if needed
  }

  _transform(chunk, _encoding, callback) {
    // TODO: implement transformation + backpressure measurement
    callback(new Error('not implemented'));
  }

  _flush(callback) {
    // TODO: signal end-of-stream to downstream
    callback();
  }
}

/**
 * Pipe source through UpperCaseTransform, collect results, track peak buffer.
 *
 * @param {Readable} source    - object-mode readable of { line, seq }
 * @param {number}   hwm       - highWaterMark for the transform
 * @returns {Promise<{ results: Array<{line:string,seq:number}>, peakBuffered: number }>}
 */
export async function processPipeline(source, hwm = 4) {
  // TODO: implement using stream.pipeline (NOT .pipe())
  // Return { results, peakBuffered }
  throw new Error('not implemented');
}
EOF

# ── test/backpressure.test.js — visible sample test ──────────────────────────
cat > "$WORK/test/backpressure.test.js" << 'EOF'
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { processPipeline, UpperCaseTransform } from '../src/transform.js';

function makeSource(n, delayMs = 0) {
  let i = 0;
  return new Readable({
    objectMode: true,
    read() {
      if (i >= n) { this.push(null); return; }
      const chunk = { line: `hello world ${i}`, seq: i };
      i++;
      if (delayMs > 0) {
        setTimeout(() => this.push(chunk), delayMs);
      } else {
        this.push(chunk);
      }
    },
  });
}

describe('UpperCaseTransform — sample tests', () => {
  it('upper-cases lines correctly', async () => {
    const src = makeSource(3);
    const { results } = await processPipeline(src, 4);
    assert.equal(results.length, 3);
    assert.equal(results[0].line, 'HELLO WORLD 0');
    assert.equal(results[0].seq, 0);
  });

  it('preserves seq numbers', async () => {
    const src = makeSource(5);
    const { results } = await processPipeline(src, 4);
    for (let i = 0; i < 5; i++) {
      assert.equal(results[i].seq, i);
    }
  });
});
EOF

# ── print next steps ──────────────────────────────────────────────────────────
echo
echo "Work directory : $WORK"
echo
echo "Task           : implement UpperCaseTransform and processPipeline in src/transform.js"
echo "                 so the node --test harness passes."
echo
echo "Prerequisites  :"
echo "  cd $WORK && npm install"
echo
echo "Run sample tests: cd $WORK && node --test test/backpressure.test.js"
echo "Verify + flag  : bash courses/course-33-node-backend-scale/challenges/05-stream-backpressure/verify.sh"
