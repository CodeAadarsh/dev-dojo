# Streaming & Backpressure

> **Module 05 · Course 33** — Most Node services never touch streams until a customer uploads a 2 GB file and the process exits with `exit code 137`. This module covers how Node's stream machinery actually works, why backpressure is the thing that saves you, and how async iterators have quietly become the cleanest way to consume a stream in modern TypeScript.

You already `pipe()` streams. This module is about understanding what happens when you don't, or when you do it wrong.

---

## The four stream types

Node's `node:stream` module exposes four abstractions. At work you use all four whether you know it or not.

```
Readable          data source               fs.createReadStream, http.IncomingMessage
Writable          data sink                 fs.createWriteStream, http.ServerResponse
Duplex            both at once              net.Socket, TLS socket
Transform         Duplex that mutates data  zlib.createGzip, crypto.createCipher
```

Every stream is an `EventEmitter` underneath, but you should rarely drop to that level yourself. The three APIs you'll actually use are:

| API | When to reach for it |
|-----|---------------------|
| `.pipe()` | Connecting two streams; handles backpressure automatically |
| `stream.pipeline()` | Same, but propagates errors and destroys all streams on failure — use this instead of `.pipe()` |
| `for await...of` | Consuming a Readable as an async iterator — most readable for logic-heavy transforms |

---

## Backpressure — the real reason streams exist

The core problem: a **fast producer + slow consumer** with nothing in between causes unbounded memory growth.

```
          1 GB/s                     10 MB/s
 producer ─────────────────────────────────────── consumer
          ↑                            ↑
   fs.createReadStream            network socket
                   ↕
          internal buffer grows until RSS hits 8 GB and the OOM killer arrives
```

Backpressure is Node's signal from the consumer back to the producer: *slow down*. The signal flows through `.write()`'s return value.

```typescript
import { createReadStream, createWriteStream } from 'node:fs';

const src = createReadStream('/data/large.csv');
const dst = createWriteStream('/tmp/out.csv');

// WRONG — writes as fast as src emits; dst buffer grows unbounded
src.on('data', (chunk) => {
  dst.write(chunk); // ignoring the return value
});

// CORRECT — stream.pipeline handles backpressure and error propagation
import { pipeline } from 'node:stream/promises';

await pipeline(src, dst);
```

When `dst.write(chunk)` returns `false`, it means the internal buffer is at or above `highWaterMark`. A well-behaved producer pauses at that point and resumes when `dst` emits `'drain'`. `stream.pipeline()` does all of this for you.

### `highWaterMark`

`highWaterMark` is the buffer size threshold, in bytes for byte streams and in object count for object-mode streams. The default is **16 KB for byte streams** and **16 objects for object-mode streams**.

```typescript
// Reading a 100 MB CSV: keep memory cost predictable
const src = createReadStream('/data/export.csv', {
  highWaterMark: 64 * 1024, // 64 KB read chunks
});

// Processing objects: small HWM = tight memory, more await overhead
const parser = new Transform({
  objectMode: true,
  highWaterMark: 32, // pause after 32 objects buffered
  transform(chunk, _enc, cb) {
    // ...
    cb(null, transformed);
  },
});
```

Raising `highWaterMark` increases throughput at the cost of more RAM buffered. The default is sane for most workloads. The time to change it is when profiling shows you're buffer-bound, not before.

---

## Transform streams

A `Transform` is a `Duplex` that maps input to output. The canonical pattern for a TypeScript service is subclassing or the functional constructor:

```typescript
import { Transform, TransformOptions } from 'node:stream';

// Functional style — no class noise
function createJsonlParser(): Transform {
  let buf = '';
  return new Transform({
    readableObjectMode: true,
    writableObjectMode: false,
    transform(chunk: Buffer, _enc, callback) {
      buf += chunk.toString('utf8');
      const lines = buf.split('\n');
      buf = lines.pop() ?? ''; // keep incomplete trailing line
      for (const line of lines) {
        if (line.trim()) {
          try {
            this.push(JSON.parse(line));
          } catch {
            callback(new Error(`Invalid JSON: ${line.slice(0, 80)}`));
            return;
          }
        }
      }
      callback();
    },
    flush(callback) {
      if (buf.trim()) {
        try {
          this.push(JSON.parse(buf));
        } catch {
          callback(new Error(`Incomplete JSONL at end of stream`));
          return;
        }
      }
      callback();
    },
  });
}
```

Two things to get right every time:
- **`_flush`** — called when the upstream ends; emit any leftover buffered data or error out.
- **`callback(error)`** — the only safe way to signal a transform error. Never `throw` inside a `transform` handler.

---

## Async iterators — the modern interface

Since Node 10, every `Readable` implements `Symbol.asyncIterator`. This means you can consume a stream with `for await...of`, which composes naturally with TypeScript's type system and avoids the event-emitter callback pyramid.

```typescript
import { createReadStream } from 'node:fs';
import { createInterface } from 'node:readline';

async function processCsvFile(path: string): Promise<number> {
  const src = createReadStream(path, { encoding: 'utf8' });
  const rl = createInterface({ input: src, crlfDelay: Infinity });

  let rows = 0;
  for await (const line of rl) {
    if (rows === 0) { rows++; continue; } // skip header
    await processRow(line);
    rows++;
  }
  return rows;
}
```

`readline.createInterface` is the built-in way to iterate a stream line by line — it handles partial chunks internally. The `for await` loop applies backpressure automatically: it won't call `next()` until you `await` the body, so the underlying read pauses when you're processing.

### Piping to an HTTP response

Streaming a large file to an HTTP response is the same pattern — `stream.pipeline` owns the lifecycle:

```typescript
import { pipeline } from 'node:stream/promises';
import { createReadStream } from 'node:fs';
import { createGzip } from 'node:zlib';
import type { ServerResponse } from 'node:http';

async function streamGzippedFile(path: string, res: ServerResponse) {
  res.setHeader('Content-Encoding', 'gzip');
  res.setHeader('Content-Type', 'application/octet-stream');
  try {
    await pipeline(createReadStream(path), createGzip(), res);
  } catch (err) {
    // pipeline destroys all streams; response may be partially sent
    if (!res.headersSent) {
      res.writeHead(500);
    }
    res.end();
  }
}
```

`pipeline` destroys every stream in the chain when any one of them errors or when the destination closes early (client disconnect). Without `pipeline`, a disconnected client leaves you with an `fs.ReadStream` and a `Gzip` that nobody is draining — a slow file-descriptor leak that only shows up under load.

---

## Memory safety checklist

The rules that prevent the 2 AM OOM alert:

1. **Never `await res.json()` or `.buffer()` on a response you don't own the size of.** If the upstream can return large payloads, stream or set a `maxResponseSize` check.
2. **Always use `stream.pipeline` (not raw `.pipe()`)** so destroyed streams on error don't leak.
3. **Attach error handlers** on every stream before `.pipe()` if you're not using `pipeline`. An unhandled `'error'` event crashes the process.
4. **Watch RSS under load** — `process.memoryUsage().rss` logged every 60 seconds is cheap and tells you when something is buffering silently.
5. **Don't read the whole stream into memory** for validation. Parse incrementally and reject early.

```typescript
// Cheap RSS monitor — add to your server startup
setInterval(() => {
  const mb = Math.round(process.memoryUsage().rss / 1024 / 1024);
  if (mb > 512) console.warn({ event: 'high_rss', rss_mb: mb });
}, 60_000).unref();
```

`.unref()` means this timer won't keep the process alive — it fires only as long as the server is running for other reasons.

---

## Debugging Streams

### Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| RSS climbs steadily under sustained upload traffic, OOM after minutes | Pipe without backpressure: `src.on('data', dst.write)` ignoring return value | Replace with `stream.pipeline(src, dst)` |
| Process crashes with `Error: write after end` | Producer writing to a stream after `end()` or `destroy()` — often race with client disconnect | Check `writable.writable` before writing; use `pipeline` so destroy is coordinated |
| Transform silently swallows records | `callback()` called without an error but `this.push()` never called — output ends early | Add a test that counts pushed objects; ensure `push` is called for every valid input |
| `Error: stream was destroyed` logged by Node but no stack | `.pipe()` destination destroyed (client disconnect) with no error handler on the source | Attach `src.on('error', handler)` or switch to `pipeline` which handles this |
| Memory spike on large `PUT` requests | Route handler calling `req.json()` or reading `req.body` in full | Stream the request body through a Transform or a size-limited reader |
| No output from a Transform that looks correct | `_flush` not calling `callback()` — stream hangs forever | `flush(cb) { this.push(remaining); cb(); }` — always call `cb()` |

### Diagnosing OOM from stream buffering

When RSS climbs in a streaming path, add a quick probe:

```typescript
// Temporarily instrument a stream to log buffered bytes
function watchBufferDepth(stream: NodeJS.ReadableStream, label: string) {
  stream.on('data', () => {
    const r = stream as any;
    const depth = r._readableState?.length ?? 0;
    if (depth > 1024 * 1024) {
      console.warn({ label, buffered_bytes: depth, event: 'backpressure_ignored' });
    }
  });
}
```

`_readableState.length` is internal but stable across Node versions and safe to read (never write). If it grows without bound, backpressure isn't being applied.

> **War story.** A log-pipeline service at SAP ingested ~100 GB/day from 40 upstream sources via HTTP POST. Under a burst (all 40 sources reconnecting simultaneously after a short outage), RSS climbed from 150 MB to 6 GB in under two minutes and the pod was OOM-killed. The code looked like `for await (const chunk of req) { queue.push(chunk); }` — perfectly idiomatic — but `queue.push` was synchronous, the loop never paused, and the queue had no backpressure callback. The fix was a `Transform` that called its `callback` only after `queue.enqueue()` resolved (a promise that resolved when the queue drained below its HWM). Buffer depth went from unbounded to ≤64 KB per connection under the same burst. The lesson: `for await` applies backpressure to the stream it reads from, but the write side needs its own flow control.

---

## Checkpoint

You're ready for the streaming challenges when you can, without looking anything up:

1. Explain in one sentence what backpressure is and name the signal Node uses to communicate it.
2. Write a `stream.pipeline` call that reads a file, gzips it, and writes to a response — and explain what happens on client disconnect.
3. Name the two things you must always do in `_flush`.
4. Explain why `for await...of` on a `readline.Interface` applies backpressure, but `src.on('data', queue.push)` doesn't.
5. Given a memory leak under upload load, name the first metric you check and the command to read it.
6. Explain why you `.unref()` a monitoring `setInterval`.
7. Describe the difference in error propagation between `.pipe()` and `stream.pipeline()`.

➡ Next up: **Testing & Observability** — making sure the streams (and everything else) behave correctly in CI and telling you when they don't in production.
