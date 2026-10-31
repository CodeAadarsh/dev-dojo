# Pub/Sub & Streams

> **Module 06 · Course 19** — Redis has two messaging primitives that look similar but serve completely different contracts. Pub/Sub is fire-and-forget: if no subscriber is connected when you publish, the message is gone. Streams are a persistent, consumer-group-aware log — closer to Kafka than to a message bus. Knowing which to reach for (and why) is the practical skill this module builds.

Both primitives are used constantly in production, and both are also commonly misused. By the end of this module you should be able to design a messaging topology, implement consumer groups with proper acknowledgment, and diagnose the failure modes that silently eat messages in each system.

---

## 1. Pub/Sub — Fire and Forget

### 1.1 The Model

Pub/Sub in Redis is channel-based publish–subscribe with **zero durability**. A publisher sends a message to a channel; every subscriber currently listening on that channel receives it. If no subscribers are listening, the message is discarded — there is no buffer, no replay.

```
  Publisher (PUBLISH notifications:email "user:123")
       │
       │  messages flow through in-memory channel dispatch
       ▼
  ┌────────────────────────────────────────────────────┐
  │  redis-server  (channel: notifications:email)       │
  └────────────────────────────────────────────────────┘
       │          │          │
       ▼          ▼          ▼
  Subscriber-1  Subscriber-2  (no Subscriber-3 — it joined 1 second late)
  receives it   receives it   → message is GONE for Subscriber-3
```

### 1.2 Commands

```bash
# Terminal 1 — subscribe
redis-cli SUBSCRIBE notifications:email notifications:sms

# Terminal 2 — publish
redis-cli PUBLISH notifications:email "user:123 confirmed"
# returns: (integer) 2  → number of subscribers that received the message

redis-cli PUBLISH notifications:push "user:456 alert"
# returns: (integer) 0  → nobody was subscribed to this channel
```

When subscribed, `redis-cli` enters a read-only receive loop. The wire format for a received message is a three-element array: `["message", "<channel>", "<payload>"]`.

**Pattern subscriptions** let you subscribe to a glob:

```bash
redis-cli PSUBSCRIBE "notifications:*"
# matches: notifications:email, notifications:sms, notifications:push, etc.

# Wire format is a four-element array:
# ["pmessage", "<pattern>", "<channel>", "<payload>"]
```

Listing active channels and subscription counts:

```bash
redis-cli PUBSUB CHANNELS "notifications:*"    # active channels matching glob
redis-cli PUBSUB NUMSUB notifications:email    # subscriber count per channel
redis-cli PUBSUB NUMPAT                        # total pattern subscription count
```

### 1.3 When Pub/Sub is the Right Choice

Use Pub/Sub when:
- Delivery to *currently connected* subscribers is all you need.
- You are implementing **real-time presence**, websocket fan-out, or live dashboard updates.
- Messages are truly ephemeral — a second late subscriber has no use for the missed message.
- You need low-overhead broadcast to N clients with no acknowledgment.

Do **not** use Pub/Sub when:
- You need guaranteed delivery (subscribers restart, crash, or lag behind publishers).
- You need to replay past events.
- You need to track which consumers processed which messages.
- Publisher rate can exceed subscriber processing rate (no backpressure, no queue — messages silently drop).

> **Real example.** A WebSocket server fanning out live price ticks to N connected clients is a perfect Pub/Sub use case. Each tick is only useful right now; a client that missed it will get the next one. A background job that processes order events must not use Pub/Sub — if the job restarts and misses 30 seconds of events, those orders are never processed. Use Streams for that.

---

## 2. Streams — Durable, Ordered, Consumer-Group-Aware

Redis Streams (introduced in Redis 5.0) is a persistent log data structure. Think of it as an append-only log that supports:

- **Multiple consumer groups** reading the same stream concurrently, each at their own offset.
- **Acknowledgment** (a consumer explicitly tells Redis "I processed this entry") so that unacknowledged entries can be detected and redelivered.
- **At-least-once delivery** semantics by design.
- **Backpressure** via `XLEN` monitoring and trimming policies.

```
  Stream: events:orders
  ┌──────────────────────────────────────────────────────────────────────┐
  │  1700000001000-0  │  order_id=1  status=placed  user=123            │
  │  1700000002000-0  │  order_id=2  status=placed  user=456            │
  │  1700000003000-0  │  order_id=3  status=paid    user=123            │
  │  1700000004000-0  │  order_id=1  status=shipped user=123            │
  │  …                │                                                  │
  └──────────────────────────────────────────────────────────────────────┘
            ▲                                              ▲
  Consumer Group "billing"                     Consumer Group "fulfillment"
  last-delivered-id: 1700000003000-0           last-delivered-id: 1700000002000-0
  (each group tracks independently)
```

### 2.1 Stream IDs

Every entry in a stream has an auto-generated ID of the form `<milliseconds>-<sequence>`. The milliseconds component is the Redis server's wall clock at insertion time; the sequence is a counter that handles sub-millisecond batches.

```bash
XADD events:orders '*' order_id 1 status placed user 123
# returns: "1700000001000-0"

# Explicit ID (useful for idempotent imports):
XADD events:orders 1700000001000-0 order_id 1 status placed user 123
# returns: "1700000001000-0" — fails if that ID already exists
```

The `*` wildcard generates the next auto-ID. Use explicit IDs only when migrating data or enforcing idempotency via an external ID.

### 2.2 Reading — XRANGE, XREVRANGE, XREAD

```bash
# Read all entries from ID 0 (beginning) to + (end):
XRANGE events:orders - +

# Read entries from a specific time window:
XRANGE events:orders 1700000001000-0 1700000003000-0

# Reverse chronological (most recent first):
XREVRANGE events:orders + - COUNT 10

# Block until new entries arrive (0 = wait forever):
XREAD BLOCK 0 STREAMS events:orders $
# '$' means "only new entries after now"
```

`XREAD` without a consumer group is a simple "read from here" with no acknowledgment. Every caller sees all entries independently — there is no coordination. This is suitable for a single consumer or when you want every service to see every event (fan-out).

```bash
XLEN events:orders                        # entry count
XINFO STREAM events:orders                # metadata: length, first/last ID, etc.
XINFO GROUPS events:orders                # all consumer groups on this stream
XINFO CONSUMERS events:orders billing     # consumers within a group
```

### 2.3 Consumer Groups — The Core Pattern

A consumer group allows multiple consumers to share the work of processing a stream. The group tracks:
- **`last-delivered-id`**: the highest entry ID delivered to any consumer in the group.
- **PEL** (Pending Entry List): entries delivered but not yet acknowledged.

```bash
# Create a group starting from the beginning (0) or from now ($):
XGROUP CREATE events:orders billing 0 MKSTREAM
XGROUP CREATE events:orders fulfillment $ MKSTREAM
# MKSTREAM creates the stream if it doesn't exist yet
```

**XREADGROUP** — read entries assigned to a specific consumer:

```bash
# Consumer "worker-1" in group "billing" reads up to 10 entries:
XREADGROUP GROUP billing worker-1 COUNT 10 STREAMS events:orders >
# '>' means "give me new (undelivered to this group) entries"
```

The `>` symbol is special: it advances `last-delivered-id`. If you pass an ID (e.g., `0`) instead of `>`, you get entries from the PEL — entries previously delivered to *any* consumer in the group but not yet acknowledged.

```
  Stream entries: A  B  C  D  E  F  G
                                    ▲ last-delivered-id = G
  
  PEL for group "billing":
    worker-1: [A, C]    (delivered, not yet ACK'd)
    worker-2: [B, D, E] (delivered, not yet ACK'd)
    (F and G are already ACK'd and no longer in PEL)
```

**XACK** — acknowledge successful processing:

```bash
XACK events:orders billing 1700000001000-0 1700000003000-0
# removes those IDs from the PEL; they are "done"
```

**XPENDING** — inspect the PEL:

```bash
# Summary: how many pending, oldest/newest ID, per-consumer counts
XPENDING events:orders billing

# Detail: all pending entries with delivery count and idle time
XPENDING events:orders billing - + 100

# Output:
# 1700000001000-0  worker-1  143200  (idle ms)  3  (delivery count)
# 1700000003000-0  worker-1  143200             1
```

**XCLAIM** — transfer ownership of a stuck entry to another consumer:

```bash
# Take ownership of an entry idle > 60 seconds (a stalled worker)
XCLAIM events:orders billing worker-2 60000 1700000001000-0
# Now worker-2 is responsible for this entry; delivery count incremented
```

The `delivery_count` field in `XPENDING` is critical: if a message is being redelivered many times and never acknowledged, it is a **poison pill** — processing always fails. You should detect these (delivery count > threshold) and route them to a dead-letter stream:

```bash
XADD events:orders:dlq '*' original_id 1700000001000-0 error "parse failed" consumer worker-1
XACK events:orders billing 1700000001000-0
```

### 2.4 XAUTOCLAIM — Batch Reclaim Idle Entries

Redis 6.2 added `XAUTOCLAIM`, which atomically scans the PEL for entries idle beyond a threshold and reassigns them:

```bash
# Scan PEL from 0-, reclaim entries idle > 30s, up to 100 at a time
XAUTOCLAIM events:orders billing worker-2 30000 0- COUNT 100
# Returns: [next_start_id, claimed_entries, deleted_ids]
```

In a recovery loop, a watchdog consumer calls `XAUTOCLAIM` periodically to recover entries from dead workers. The `next_start_id` tells you where to continue the next scan — loop until it returns `0-0` (meaning the entire PEL was scanned).

### 2.5 Stream Trimming — MAXLEN and MINID

Streams grow forever by default. Two trimming strategies:

```bash
# Trim to the most recent N entries (approximate with ~ for efficiency):
XADD events:orders '*' MAXLEN ~ 10000 order_id 5 status placed user 789
# The '~' allows Redis to trim to a round number > 10000 for radix-tree efficiency

# Trim to exact count (expensive on large streams):
XTRIM events:orders MAXLEN 10000

# Trim by minimum ID (drop everything older than a timestamp):
XTRIM events:orders MINID 1700000000000-0
```

> **MAXLEN ~ vs MAXLEN (exact).** The radix tree (rax) that backs a stream stores entries in 4096-byte nodes. An exact trim may split a node, fragmenting memory. The `~` form trims only at node boundaries, which is O(1) amortized per entry. Use exact trimming only when you have a hard space constraint that overrides efficiency.

### 2.6 XDEL and the Tombstone Problem

`XDEL` removes a specific entry from a stream but does **not** shrink the radix tree node it lives in — the node persists with a tombstone. Use `XDEL` sparingly (e.g., GDPR compliance for a specific event). For bulk removal, `XTRIM` is correct.

---

## 3. At-Least-Once Delivery — The Guarantee and Its Limits

Redis Streams provides at-least-once delivery within the scope of a **single Redis instance** (or Cluster shard). Specifically:

- An entry written with `XADD` persists until `XDEL` or `XTRIM` removes it, regardless of consumer state.
- An entry stays in the PEL until explicitly acknowledged.
- If a consumer crashes before `XACK`, the entry remains in the PEL and can be reclaimed.

What it does **not** guarantee:
- **Exactly-once.** A consumer can receive and process an entry, crash before `XACK`, and have the entry redelivered. Your processing must be idempotent.
- **Durability across Redis restarts without AOF.** If Redis restarts and is configured with RDB-only persistence, some entries written since the last RDB snapshot may be lost. For messaging use cases, run with `appendonly yes`.
- **Cross-shard atomicity in Cluster.** An `XADD` to a key on shard A and the acknowledgment via `XACK` on shard B are independent operations — there is no two-phase commit.

---

## Debugging Pub/Sub & Streams

### Lost Pub/Sub Messages

The most common cause is: **the subscriber was not connected when the message was published**. This is a design failure, not a Redis bug. The diagnostic path:

```bash
# On the publisher:
redis-cli PUBLISH notifications:email "test"
# If this returns 0, no one is subscribed right now

# List all active channels (those with at least one subscriber):
redis-cli PUBSUB CHANNELS "*"

# Are your subscribers running?
# Redis itself has no history to query. Look at your application logs.
```

Other causes:
1. **Subscriber slow consumer.** Redis drops messages for a slow subscriber once the output buffer fills. Watch `CLIENT LIST` for `omem` (output buffer) growing:
   ```bash
   redis-cli CLIENT LIST | grep -E 'flags=S|omem'
   # flags=S = subscriber mode; omem = output buffer bytes
   ```
   If `omem` is non-zero and growing, your subscriber is not consuming fast enough.
2. **Network split.** The subscriber's TCP connection dropped silently. Implement reconnect logic with SUBSCRIBE re-issue on reconnect.
3. **Pattern mismatch.** `PSUBSCRIBE notifications:*` does NOT match `notification:email` (singular). Test patterns with `PUBSUB CHANNELS <pattern>`.

### Growing PEL — Unacked Entries Piling Up

The PEL grows when consumers take entries but never call `XACK`. This is a slow leak that eventually consumes significant memory and makes `XPENDING` queries slow.

```bash
# How big is the PEL?
XPENDING events:orders billing
# Output: (integer) 150000  ← that's a problem

# Find entries with high delivery count (poison pills):
XPENDING events:orders billing - + 100
# Look at the 4th column (delivery count) — anything > 3-5 needs investigation

# Memory used by the stream:
MEMORY USAGE events:orders
```

Fixing a growing PEL:
1. **Find and fix the bug** preventing `XACK`. The processing code has an exception that exits before the ack.
2. **Dead-letter loop** for high-delivery-count entries — write a consumer that reads the PEL (`XREADGROUP ... 0`), routes high-delivery-count entries to a DLQ stream, and acks them.
3. **XAUTOCLAIM** to redistribute stuck work to healthy consumers.
4. **Never trim the PEL directly.** `XDEL` removes an entry from the stream but leaves it in the PEL — leading to ghost entries (in PEL but not in stream). Always `XACK` before `XDEL`.

### Unacked Entries After a Consumer Restart

```bash
# Worker restarts; drain its own PEL first (use ID '0' not '>'):
XREADGROUP GROUP billing worker-1 COUNT 100 STREAMS events:orders 0
# Process these, then XACK, then switch to '>' for new entries

# Or: use XCLAIM to reassign them to yourself if ownership is unclear:
XPENDING events:orders billing - + 100
# Note IDs with worker-1 ownership, then process and ACK
```

The pattern in a robust consumer:
```
1. XREADGROUP ... 0   → drain own PEL
2. process + XACK
3. XREADGROUP ... >   → read new entries
4. process + XACK
5. if step 3 returns empty: XAUTOCLAIM (recover orphaned entries from dead workers)
6. BLOCK and repeat
```

### Detecting Stream Growth Exceeding Budget

```bash
# Poll XLEN in a monitoring loop:
redis-cli XLEN events:orders   # entry count

# With INFO:
redis-cli INFO memory | grep used_memory_human

# In production, alert when XLEN > threshold and consumers are not keeping up:
redis-cli XINFO GROUPS events:orders | grep lag
# lag = last-delivered-id minus stream last-entry-id, in entry count
# lag > 0 means consumers are behind
```

---

## Checkpoint

Answer without notes:

1. `PUBLISH notifications:email "test"` returns `(integer) 0`. What does this mean? Is anything wrong with Redis?
2. Explain the difference between `XREAD STREAMS events:orders $` and `XREADGROUP GROUP billing worker-1 STREAMS events:orders >`. When does each increment the group's `last-delivered-id`?
3. A consumer calls `XREADGROUP GROUP billing worker-1 STREAMS events:orders 0`. What does the `0` mean vs `>`? Why would you use `0` on startup?
4. What is the PEL? What event adds an entry to the PEL, and what event removes it?
5. A stream has 50,000 entries with delivery count > 10. What is a poison pill and how do you handle it without corrupting the PEL?
6. `XAUTOCLAIM events:orders billing worker-2 30000 0- COUNT 100` returns a `next_start_id` of `1700000005000-0`. What does this mean, and what should your watchdog do next?
7. You run `XTRIM events:orders MAXLEN 10000` and then `XPENDING events:orders billing` still shows those entries as pending. Why? Is this a bug?
8. Your stream consumer subscribes to a Pub/Sub channel for low-latency updates AND reads from a Stream for durability. Sketch the two parallel goroutines/threads and explain which path is authoritative.

➡ Next: **Transactions, Scripting & Patterns** — MULTI/EXEC/WATCH, Lua atomicity, and the canonical Redis patterns you'll use in every production service.
