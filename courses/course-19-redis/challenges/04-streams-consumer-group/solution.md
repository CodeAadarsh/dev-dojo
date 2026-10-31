# Solution: Streams & Consumer Groups

## Redis Streams internals primer

Before the commands, internals. A Redis Stream is stored as a **radix tree of listpack nodes** under the hood. Each node holds a compact run of entries. The key insight is that unlike a list (which is a linked sequence of values), a stream entry is a **map** (field-value pairs) with a **globally unique, monotonically increasing ID**. The ID encodes millisecond wall time plus a sequence number — two entries added in the same millisecond get IDs like `1700000000000-0` and `1700000000000-1`.

```
Stream internals (simplified)
  Key: dojo:events   (type = stream)
  ┌─────────────────────────────────────────────────────────────────┐
  │  radix tree root                                                │
  │    └── node (listpack, entries 0..4)                           │
  │         ├── 1700000000000-0  {event_type:order_placed, ...}    │
  │         ├── 1700000000001-0  {event_type:order_placed, ...}    │
  │         ├── 1700000000002-0  {event_type:order_shipped, ...}   │
  │         ├── 1700000000003-0  {event_type:order_placed, ...}    │
  │         └── 1700000000004-0  {event_type:order_cancelled, ...} │
  └─────────────────────────────────────────────────────────────────┘
```

This structure is why `XRANGE` is O(N) where N is the number of entries returned (not total stream length), and why `XLEN` is O(1) — Redis maintains a counter in the stream metadata.

A **consumer group** adds a second layer of metadata on top of the stream:

```
Consumer Group: dojo-workers
  last-delivered-id  → the ID of the last entry dispatched to any consumer
  PEL (Pending Entries List):
    entry-id → { consumer-name, delivery-timestamp, delivery-count }
  Consumers:
    worker-1 → { pending-count, idle-since }
```

The PEL is the at-least-once guarantee. If `worker-1` dies between `XREADGROUP` and `XACK`, the PEL retains the entry. An operator can find it, reassign it, and ensure it is processed exactly once by application-level deduplication.

## Step-by-step walkthrough

### Step 1: Inspect the seeded stream

```bash
docker exec dojo-redis redis-cli XRANGE dojo:events - +
```

Output (IDs will differ — they are real millisecond timestamps from when setup ran):

```
1) 1) "1700000000123-0"
   2) 1) "event_type"
      2) "order_placed"
      3) "order_id"
      4) "ORD-1001"
      5) "product"
      6) "widget-a"
      7) "qty"
      8) "3"
      9) "user_id"
      10) "U-42"
2) 1) "1700000000124-0"
   ...
```

The IDs are the keys you'll use with `XACK`. Take note of all five.

You can also get a quick summary:

```bash
docker exec dojo-redis redis-cli XINFO STREAM dojo:events
```

This shows length, first/last entry IDs, and the internal radix tree node count.

### Step 2: Create the consumer group

```bash
docker exec dojo-redis redis-cli XGROUP CREATE dojo:events dojo-workers 0
```

**Why `0` and not `$`?**

- `0` means "the group starts delivering from the very first entry in the stream" — it will see all existing entries.
- `$` means "start from entries added *after* this moment" — existing entries are skipped.

In the production scenario (a crashed worker, recovery), you want `0` or the last-known-processed ID so no entries are skipped.

The `MKSTREAM` flag (optional here) creates the stream if it does not exist:
```bash
docker exec dojo-redis redis-cli XGROUP CREATE dojo:events dojo-workers 0 MKSTREAM
```

After this, `XINFO GROUPS dojo:events` shows `last-delivered-id = 0-0` and `pending = 0`.

### Step 3: Read all messages as worker-1

```bash
docker exec dojo-redis redis-cli XREADGROUP GROUP dojo-workers worker-1 \
    COUNT 10 STREAMS dojo:events ">"
```

**Breaking down the syntax:**

| Argument | Meaning |
|----------|---------|
| `GROUP dojo-workers worker-1` | Read as consumer `worker-1` belonging to group `dojo-workers` |
| `COUNT 10` | Return at most 10 entries per call |
| `STREAMS dojo:events` | Which streams to read (can be multiple) |
| `">"` | The special delivery cursor — "entries not yet delivered to any consumer in this group" |

After this call:
- `last-delivered-id` advances to the ID of the 5th entry.
- All 5 entry IDs are now in the PEL, assigned to `worker-1`.
- A second `XREADGROUP ... ">"` would return 0 entries (nothing new to deliver).

Confirm:

```bash
# Summary: total pending, min/max PEL IDs, per-consumer counts
docker exec dojo-redis redis-cli XPENDING dojo:events dojo-workers

# Detailed: each PEL entry with consumer, idle time, delivery count
docker exec dojo-redis redis-cli XPENDING dojo:events dojo-workers - + 10
```

The detailed form output looks like:

```
1) 1) "1700000000123-0"
   2) "worker-1"
   3) (integer) 3847      <- milliseconds since last delivery
   4) (integer) 1         <- delivery count (1 = delivered once, never redelivered)
```

### Step 4: Acknowledge four entries

Copy four of the five IDs from the `XPENDING` output. The fifth (any one) is left unacked to simulate the crash scenario.

```bash
docker exec dojo-redis redis-cli XACK dojo:events dojo-workers \
    1700000000123-0 1700000000124-0 1700000000125-0 1700000000126-0
```

`XACK` returns the count of entries actually removed from the PEL (should be 4).

What XACK does internally:
1. Removes each entry from the PEL.
2. Decrements the group's `pending` counter.
3. Does **not** delete the entry from the stream itself — the stream entry persists until `XTRIM` or `DEL`.

### Step 5: Confirm PEL state

```bash
# Summary form — first field is the total pending count
docker exec dojo-redis redis-cli XPENDING dojo:events dojo-workers
```

Expected output:
```
1) (integer) 1               <- exactly 1 pending
2) "1700000000127-0"         <- its ID
3) "1700000000127-0"
4) 1) 1) "worker-1"
         2) "1"
```

Run the verifier:

```bash
bash courses/course-19-redis/challenges/04-streams-consumer-group/verify.sh
```

## Production patterns beyond this challenge

**Claiming stale PEL entries with XCLAIM**

When `worker-1` has been dead for more than 30 seconds, another worker can claim its unacked entries:

```bash
# Find entries idle > 30000ms
docker exec dojo-redis redis-cli XPENDING dojo:events dojo-workers - + 10

# Reassign the stale entry to worker-2 (min-idle-ms = 30000)
docker exec dojo-redis redis-cli XCLAIM dojo:events dojo-workers worker-2 \
    30000 1700000000127-0
```

In Redis 6.2+, `XAUTOCLAIM` does this in one command:

```bash
docker exec dojo-redis redis-cli XAUTOCLAIM dojo:events dojo-workers worker-2 \
    30000 0-0 COUNT 10
```

**Capping stream length to avoid unbounded growth**

Streams grow forever unless trimmed. In production:

```bash
# Trim to at most 1 million entries (approximate, uses ~ for efficiency)
docker exec dojo-redis redis-cli XTRIM dojo:events MAXLEN ~ 1000000

# Or add to XADD directly:
docker exec dojo-redis redis-cli XADD dojo:events MAXLEN ~ 1000000 '*' key value
```

**Monitoring**

The metrics to alert on:
- `XLEN dojo:events` — stream growth rate.
- `XPENDING dojo:events dojo-workers` first field — PEL depth.
- `XINFO GROUPS dojo:events` → `lag` field (Redis 7.0+) — entries added after `last-delivered-id`, not yet dispatched to any consumer.

## Debugging Streams

**`XREADGROUP` returns nothing (0 entries) when `>` is used:**
The group's `last-delivered-id` has already passed all existing entries. Either the group was created with `$` (too late), or you already read them. Confirm with `XINFO GROUPS` — if `last-delivered-id` equals the stream's last entry ID, everything has been dispatched at least once.

**Re-reading PEL entries (redelivery):**
Use a specific ID instead of `>`:
```bash
# Re-read entries assigned to worker-1 that are still in PEL
docker exec dojo-redis redis-cli XREADGROUP GROUP dojo-workers worker-1 \
    COUNT 10 STREAMS dojo:events 0
```
The `0` cursor means "give me my PEL entries" (already-delivered, not-yet-acked), not new ones.

**Group already exists error on re-run:**
`(error) BUSYGROUP Consumer Group name already exists`. Delete with:
```bash
docker exec dojo-redis redis-cli XGROUP DESTROY dojo:events dojo-workers
```
Then recreate. `setup.sh` handles this by `DEL`-ing the entire stream.
