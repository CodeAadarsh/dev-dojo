# Stream Backpressure

The ETL team wrote a Node pipeline that reads a 500 MB log file, transforms each line, and writes results to S3. On dev laptops it runs fine. In the pod with a 256 MB memory limit it OOMKills every time. The `describe` output: `exit code 137`. `kubectl top pod` shows memory climbing linearly until the pod dies. The code: `readableStream.on('data', transform)` — classic pump-without-backpressure: the source pushes faster than the sink can drain, every object is buffered in JS heap, memory grows unbounded.

Your job: replace the event-listener style with a `Transform` stream that participates in backpressure, keeping peak memory proportional to `highWaterMark`, not data size.

## Context

`setup.sh` plants a project in your work directory:

```
~/.kube-dojo-work/05-stream-backpressure/
├── package.json          # no external deps needed
├── src/
│   └── transform.js      # implement UpperCaseTransform here
└── test/
    └── backpressure.test.js   # visible sample test
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/05-stream-backpressure
npm install
```

## Mission

Implement `UpperCaseTransform` in `src/transform.js`.

`UpperCaseTransform` is a `Transform` stream in **object mode** that:

1. Receives chunks of type `{ line: string, seq: number }`.
2. Emits `{ line: string.toUpperCase(), seq }` for each chunk.
3. Is constructed with a `{ highWaterMark }` option (default 4) that limits internal buffering.

Then implement `pipeline(source, hwm)` — an async function that:

1. Pipes `source` → `UpperCaseTransform({ highWaterMark: hwm })` → collects to an array.
2. Returns `{ results: Array<{line, seq}>, peakBuffered: number }` where `peakBuffered` is the maximum number of items buffered in the transform at any one time.
3. Uses `stream.pipeline` (or `stream/promises`) — NOT `.pipe()` — so errors propagate correctly.
4. Rejects if the source emits an error.

### What `verify.sh` checks

| Assertion | Why it matters |
|-----------|----------------|
| Output items match input with `.toUpperCase()` applied | Correctness — the transform does what it says |
| `peakBuffered <= highWaterMark` on a stream with a slow sink | Backpressure works — the source is paused, not drained into memory |
| Pipeline rejects when the source emits an error | Error propagation — `stream.pipeline` propagates errors, `.pipe()` silently drops them |

## Debugging backpressure

**Symptom:** `peakBuffered` is equal to the total number of items (no backpressure).  
**Cause:** You used `source.on('data', push)` or `.pipe()` without pausing the source. The source streams at full speed regardless of downstream pressure.  
**Fix:** Use `stream.pipeline` (or `pipeline` from `node:stream/promises`). The pipeline propagates backpressure: when your Transform's internal buffer fills to `highWaterMark`, it stops pulling from the source. Measure `peakBuffered` by incrementing a counter in `_transform` and decrementing in a `read` hook — or, simpler, check `this.readableLength` in `_transform` before pushing.

**Symptom:** Pipeline never resolves when the source finishes.  
**Cause:** `_flush` is missing. When the source ends, Node calls `_flush` on the Transform; if you don't call `callback()`, the writable side never closes.  
**Fix:** Override `_flush(callback) { callback(); }` — or if you buffer data in `_transform`, flush it here.

**Symptom:** Errors from the source don't reject the returned Promise.  
**Cause:** Using `.pipe()` instead of `stream.pipeline`. `.pipe()` does not forward errors — an error event on the source leaves the destination stream open and the Promise hanging.  
**Fix:** Use `import { pipeline } from 'node:stream/promises'; await pipeline(src, transform, dest);`. Errors on any stream in the chain reject the promise.

> **War story.** A production data export job processed 2 million rows overnight using `.on('data')` callbacks. Every row was a parsed JSON object held in memory until the downstream S3 multipart upload batch was full. On a normal night: fine. After a schema change that doubled object size: OOMKill at 3 AM, on-call paged, 6-hour pipeline restart. The fix — switching to `stream.pipeline` with a `PassThrough` as a backpressure buffer — cut peak RSS from 1.2 GB to 40 MB on the same dataset. Streams are not a performance nicety; they are a correctness guarantee about memory.

## Verify

```bash
bash courses/course-33-node-backend-scale/challenges/05-stream-backpressure/verify.sh
```

All assertions green → flag printed.
