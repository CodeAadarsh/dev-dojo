# Solution — Stream Backpressure

Complete implementation of `src/transform.js`. Key decisions explained below.

```js
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { Readable, Writable } from 'node:stream';

export class UpperCaseTransform extends Transform {
  constructor(options = {}) {
    super({
      objectMode: true,
      highWaterMark: options.highWaterMark ?? 4,
    });
    this.peakBuffered = 0;
  }

  _transform(chunk, _encoding, callback) {
    // Track how many items are currently in the readable side buffer
    // readableLength is the count of objects buffered but not yet consumed
    const buffered = this.readableLength + 1; // +1 for this chunk about to be pushed
    if (buffered > this.peakBuffered) {
      this.peakBuffered = buffered;
    }
    this.push({ line: chunk.line.toUpperCase(), seq: chunk.seq });
    callback();
  }

  _flush(callback) {
    callback();
  }
}

export async function processPipeline(source, hwm = 4) {
  const transform = new UpperCaseTransform({ highWaterMark: hwm });
  const results = [];

  const sink = new Writable({
    objectMode: true,
    write(chunk, _enc, cb) {
      results.push(chunk);
      cb();
    },
  });

  // stream.pipeline propagates errors from any stage and destroys all streams.
  // .pipe() does NOT forward errors — an error on source leaves sink open.
  await pipeline(source, transform, sink);

  return { results, peakBuffered: transform.peakBuffered };
}
```

## Why each piece is required

**`objectMode: true` + explicit `highWaterMark`.**
Node streams default to byte mode where `highWaterMark` is a byte count. In object mode, `highWaterMark` is an object count. Without `objectMode: true`, pushing a plain object causes silent corruption (objects are coerced to strings via `.toString()`). Passing `highWaterMark` to the parent constructor is how Node knows when to stop pulling from the writable side.

**`this.readableLength + 1` to measure peakBuffered.**
`readableLength` is the number of objects currently in the readable buffer (queued, waiting to be consumed). We add 1 because we're about to push the current chunk. This gives the high-water mark of the buffer before backpressure kicks in. An alternative is to use `this.push(chunk)` return value — when it returns `false`, the buffer is full.

**`callback()` in `_transform` and `_flush`.**
The `callback` is how you signal "I'm done with this chunk, give me the next one." Not calling it stalls the entire pipeline — `_transform` is never called again. It's the equivalent of ACKing a message in Kafka: without it, no more messages flow.

**`stream.pipeline` (not `.pipe()`).**
`.pipe()` propagates data but not errors. If `source` emits an error, `.pipe()` leaves the transform and sink open, the Promise never resolves, and you have a memory leak. `stream.pipeline` (from `node:stream/promises`) installs error handlers on every stage: any error destroys the whole pipeline and rejects the returned Promise.

**`Writable` sink with `objectMode: true`.**
Collecting results requires a writable that accepts objects. Without `objectMode`, each `chunk.write()` call would try to convert the object to a Buffer, throwing a `TypeError`.

## The backpressure mechanism in full

```
source  →  [highWaterMark: hwm objects]  →  Transform  →  [highWaterMark: hwm objects]  →  Writable sink
              readable buffer                                  readable buffer
```

When the transform's readable buffer hits `highWaterMark`, `push()` returns `false`. Node signals the writable side to stop calling `_transform`. The writable side signals the source to pause. The source stops reading. This chain runs in reverse when the sink drains: `sink.read()` → transform buffer drains → `push()` returns `true` → `_transform` resumes → source resumes. Peak memory is bounded by `2 × hwm × objectSize`.

## Apply and verify

```bash
# Replace src/transform.js with the solution above, then:
cd ~/.kube-dojo-work/05-stream-backpressure
node --test test/backpressure.test.js
bash courses/course-33-node-backend-scale/challenges/05-stream-backpressure/verify.sh
```
