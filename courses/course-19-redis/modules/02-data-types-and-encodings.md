# Data Types & Encodings

> **Module 02 · Course 19** — Redis stores every value twice: once as the logical type you see from the client (string, list, hash…) and once as an internal encoding chosen to minimize memory at the current size. When that encoding promotes, your memory budget may jump by 10×. This module makes that transparent.

Most developers stop at the type layer. Understanding encodings is what separates tuning Redis by intuition from tuning it by evidence.

---

## The Two-Level Model

From the client's perspective, Redis has seven main type families. From Redis's perspective, each type can be stored in one of two to four different in-memory representations, switching automatically as data grows:

```
Client type          Internal encoding (changes as data grows)
──────────────────   ─────────────────────────────────────────────────────
String               int  →  embstr  →  raw
List                 listpack  →  quicklist
Hash                 listpack  →  hashtable
Set                  listpack  →  intset  →  hashtable
Sorted Set           listpack  →  skiplist+hashtable
Stream               listpack  (per stream entry block)
HyperLogLog          raw (string, sparse/dense representation internally)
Bitmap               raw (string)
Geo                  sorted set (coordinates encoded as score)
```

Every time you write to a key, Redis checks whether the new state still fits the compact encoding. If not, it converts in place — allocating the new structure, migrating all elements, freeing the old one. This happens on the main thread, so a large promotion can add measurable latency to that one write.

---

## Strings

The String type is Redis's atomic building block. Every other type builds on it or is implemented as a top-level key. Strings are binary-safe: they hold bytes, not text, and can hold up to 512 MB.

### Three encodings

**int**: when the value is an integer that fits in a `long` (64-bit signed). Stored as the native integer, not as characters. Enables `INCR`, `DECR`, `INCRBY`, `DECRBY` to be O(1) arithmetic without parsing.

```bash
SET counter 42
OBJECT ENCODING counter      # → int
INCR counter                 # → 43 (no string parsing)
```

**embstr**: when the value is a string ≤ 44 bytes (Redis 3.2+; older versions use 39). The `redisObject` header and the SDS (Simple Dynamic String) allocation are co-located in a single `malloc()` call. This makes allocation and deallocation a single operation, and the data is cache-friendly.

```bash
SET name "aadarsh"
OBJECT ENCODING name         # → embstr
```

**raw**: anything longer than 44 bytes, or any string that has been modified (even if it ends up ≤44 bytes — an `APPEND` forces raw). Two separate allocations: the `redisObject` + an SDS struct.

```bash
SET bio "This is a longer description that exceeds 44 bytes easily"
OBJECT ENCODING bio          # → raw

SET short "hi"
APPEND short " there, world, how are you today?"
OBJECT ENCODING short        # → raw (modified, even if result fits embstr)
```

**Memory implication**: `embstr` saves one `malloc()` and typically 8–16 bytes of allocator overhead per key versus `raw`. At tens of millions of string keys, this is measurable.

### SDS: Simple Dynamic String

Redis does not use C's `\0`-terminated strings. Every string is an SDS:

```
┌──────────┬──────┬────────┬─────────────────────────────┐
│  len     │ alloc│ flags  │  buf[]                      │
│ (uint8)  │(uint8)│(1 byte)│  actual bytes + \0          │
└──────────┴──────┴────────┴─────────────────────────────┘
```

`len` stores the current length and `alloc` the allocated capacity. This means:
- `STRLEN key` is O(1) (reads `len`).
- Appending does not scan for `\0`.
- Strings are binary-safe (can contain `\0` bytes).
- SDS has several header variants (sdshdr5, sdshdr8, sdshdr16, sdshdr32, sdshdr64) chosen by length — smaller strings get smaller headers.

---

## Lists

A List is an ordered sequence of strings. It supports O(1) push/pop at both ends, making it a natural queue or stack, and O(N) indexed access.

### Encodings

**listpack** (formerly ziplist in Redis < 7.0): a compact, contiguous-memory byte sequence. Elements are stored end-to-end with length-prefix encoding. No pointers — walking requires decoding from the start. This is extremely cache-friendly for small lists.

```
┌─────────────────────────────────────────────────────────────────┐
│  listpack                                                       │
│  ┌──────┬──────┬───┬──────────────┬───┬──────────────┬─────┐   │
│  │total │ size │ e1│    entry 1   │ e2│    entry 2   │ end │   │
│  │bytes │      │len│  bytes...    │len│  bytes...    │ 0xFF│   │
│  └──────┴──────┴───┴──────────────┴───┴──────────────┴─────┘   │
└─────────────────────────────────────────────────────────────────┘
```

**quicklist**: a doubly-linked list of listpack nodes. Each node is a listpack holding up to `list-max-listpack-size` entries (default 128). This gives O(1) head/tail push/pop and bounded traversal cost per node.

```
┌─────────────────────────────────────────────────────────────────┐
│  quicklist                                                      │
│                                                                 │
│  ┌──────────┐ prev/next  ┌──────────┐ prev/next  ┌──────────┐  │
│  │ listpack │ ◄────────► │ listpack │ ◄────────► │ listpack │  │
│  │ node 1   │            │ node 2   │            │ node 3   │  │
│  │[e1,e2,…] │            │[e1,e2,…] │            │[e1,e2,…] │  │
│  └──────────┘            └──────────┘            └──────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Thresholds

```bash
# A list uses listpack encoding when BOTH conditions hold:
#   1. number of elements ≤ list-max-listpack-size
#   2. every element length ≤ list-max-ziplist-size (deprecated name; same config)
# Exceeding either converts to quicklist.

redis-cli config get list-max-listpack-size    # default: 128
redis-cli config get list-max-ziplist-size     # same setting, older name
```

Quicklist compression (`list-compress-depth`) LZ-compresses the inner listpack nodes except the first/last N, saving memory at the cost of CPU for access to middle elements. Useful for log-like structures where you mostly push/pop but rarely seek.

---

## Hashes

A Hash maps string fields to string values. Natural for structured objects.

### Encodings

**listpack**: used when the hash is small. Fields and values are stored interleaved in a single listpack. Field lookup requires a linear scan — O(N) in the number of entries, but N is bounded by the threshold so it's effectively O(1) in practice.

**hashtable**: Redis's general-purpose hash table. Uses separate chaining (linked lists of entries per bucket). Lookup is O(1) amortized. Memory overhead is higher: each entry is a `dictEntry` (three pointers = 24 bytes on 64-bit), plus the bucket array.

### Thresholds

```bash
redis-cli config get hash-max-listpack-entries  # default: 128
redis-cli config get hash-max-listpack-value    # default: 64 (bytes per field/value)
```

When either threshold is exceeded on any write, the entire hash converts from listpack to hashtable. If you store a hash with 10,000 fields, each small, it will be a hashtable even if all values are tiny.

**Memory difference example:**

```bash
# 128 small fields -> listpack (compact)
redis-cli hset user:1 $(for i in $(seq 1 128); do echo "f$i val$i"; done)
redis-cli object encoding user:1        # listpack
redis-cli memory usage user:1           # e.g. ~4 KB

# 129 fields -> hashtable (promoted)
redis-cli hset user:1 f129 val129
redis-cli object encoding user:1        # hashtable
redis-cli memory usage user:1           # e.g. ~12 KB — 3× jump
```

This is the most common source of surprise memory growth: a deployment that stores user session objects as hashes works fine in staging (few fields), but in production an extra field pushes every hash over the threshold.

---

## Sets

A Set is an unordered collection of unique strings. Supports O(1) add/remove/membership, and set-algebra operations (SUNION, SINTER, SDIFF).

### Encodings

**listpack** (Redis 7.2+): for small sets of short strings — same structure as hash listpack, elements stored sequentially. Older Redis used ziplist.

**intset**: when all members are integers. Stores them as a sorted array of `int16`/`int32`/`int64` values in a single allocation. Binary search gives O(log N) membership. Very memory-efficient: 10,000 integers in an intset use ~80 KB; in a hashtable they'd use ~640 KB.

```
┌──────────────────────────────────────────────────┐
│  intset                                          │
│  ┌────────┬──────────┬──────────────────────┐   │
│  │encoding│ length   │  int64[] sorted array│   │
│  │(2=int16│          │  [1, 5, 42, 100, ...] │   │
│  │ 4=int32│          │                       │   │
│  │ 8=int64│          │                       │   │
│  └────────┴──────────┴──────────────────────┘   │
└──────────────────────────────────────────────────┘
```

**hashtable**: general case. Once any non-integer member is added, or when the size exceeds the threshold.

### Thresholds

```bash
redis-cli config get set-max-intset-entries     # default: 512
redis-cli config get set-max-listpack-entries   # default: 128
redis-cli config get set-max-listpack-value     # default: 64
```

Promotion path: listpack/intset → hashtable. Adding a single non-integer to a 512-member intset promotes it to hashtable immediately.

---

## Sorted Sets (ZSets)

A Sorted Set is a set of unique members each with a floating-point score. Members are ordered by score (ties broken by lexicographic order of the member string). Supports O(log N) rank queries, range queries by score, and O(1) score updates.

### Encodings

**listpack**: for small sorted sets. Members and scores stored interleaved. Insertion maintains sort order by linear scan — O(N), but N is small by threshold.

**skiplist + hashtable**: the dual-structure encoding used for all large sorted sets. This is one of Redis's most elegant design choices.

```
┌─────────────────────────────────────────────────────────────────────┐
│  ZSet (skiplist+hashtable) encoding                                 │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────┐      │
│  │                    skiplist                              │      │
│  │  level 3:  head ──────────────────────────── node:100   │      │
│  │  level 2:  head ───── node:42 ─────────────  node:100   │      │
│  │  level 1:  head ─ n:1 ─ n:5 ─ n:42 ─ n:67 ─ node:100   │      │
│  └──────────────────────────────────────────────────────────┘      │
│  Gives O(log N) ZRANK, ZRANGE, ZRANGEBYSCORE                       │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────┐      │
│  │                    hashtable                             │      │
│  │  member → score  (for O(1) ZSCORE, ZADD score update)   │      │
│  └──────────────────────────────────────────────────────────┘      │
│  Both structures share pointers to the same member SDS objects      │
└─────────────────────────────────────────────────────────────────────┘
```

Why both? The skiplist alone gives O(log N) rank/range queries but O(log N) score lookup. The hashtable gives O(1) score lookup (`ZSCORE`) and O(1) existence check. Together they deliver the full sorted-set API at optimal complexity for each operation.

### Thresholds

```bash
redis-cli config get zset-max-listpack-entries   # default: 128
redis-cli config get zset-max-listpack-value     # default: 64
```

### Skiplist internals

A skiplist is a probabilistic data structure with multiple layers of linked lists. The bottom layer links all nodes in sorted order. Higher layers skip over elements, like express lanes on a highway. Lookup navigates from the highest populated level down, skipping large spans before narrowing.

Redis's skiplist implementation: each node has a random level from 1 to 32, with probability `p = 0.25` for each additional level. Expected O(log N) steps for search, insert, and delete.

---

## Streams

A Stream is an append-only log of entries, each with a unique auto-generated ID (millisecond timestamp + sequence). Supports consumer groups, acknowledgment, and pending entry lists — a full message queue primitive.

### Encoding

Streams use **listpack** for each "macro node" (a batch of entries sharing the same millisecond). When a macro node exceeds `stream-node-max-bytes` (4096) or `stream-node-max-entries` (100), a new node starts. The full stream is a radix tree of listpack nodes.

```bash
XADD mystream "*" field1 value1 field2 value2
# Entry ID: 1714123456789-0

XLEN mystream
XRANGE mystream - +    # - = first entry, + = last entry

OBJECT ENCODING mystream   # → stream
```

---

## Bitmaps

Bitmaps are not a separate data type — they are strings used via bit-level commands:

```bash
SETBIT pageviews:user:1 0 1      # bit 0 = day 0 view
SETBIT pageviews:user:1 6 1      # bit 6 = day 6 view
GETBIT pageviews:user:1 6        # → 1
BITCOUNT pageviews:user:1        # count of set bits (days with visits)

OBJECT ENCODING pageviews:user:1 # → raw (it's just a string)
```

The string is auto-extended to accommodate any bit offset. Bit offset 262143 (32 KB - 1 bit) is the practical limit for an efficiently stored bitmap. Sparse bitmaps with high offsets waste memory — use HyperLogLog or a sorted set instead.

`BITPOS` finds the first set or unset bit. `BITOP` does bitwise AND/OR/XOR/NOT across multiple bitmap keys.

---

## HyperLogLog

HyperLogLog (HLL) is a probabilistic cardinality estimator. It answers "how many unique items have I seen?" with ~0.81% error and a fixed 12 KB memory cost, regardless of cardinality.

```bash
PFADD visits user:1 user:2 user:3 user:2 user:1   # add "observations"
PFCOUNT visits                                      # → 3 (unique count estimate)

PFMERGE combined visits-mobile visits-desktop       # merge two HLLs
PFCOUNT combined                                    # total unique across both
```

HLL has two internal representations:
- **Sparse**: when few registers are non-zero (early stages). Stored as a variable-length encoding. Uses a tiny amount of RAM.
- **Dense**: when enough registers are populated. Fixed 12 KB array of 6-bit counters.

The transition from sparse to dense happens at `hll-sparse-max-bytes` (default: 3000 bytes). After that, memory is fixed regardless of elements seen.

**Use case**: counting unique visitors, unique errors, unique IPs — anywhere you need cardinality at scale and can tolerate ~1% error. A HLL counting 1 billion unique users uses the same 12 KB as one counting 100.

---

## Geo

Geo is implemented on top of a sorted set. Coordinates are encoded as a geohash-derived 52-bit integer and stored as the score:

```bash
GEOADD locations 77.5946 12.9716 "bangalore"     # lng lat name
GEOADD locations 72.8777 19.0760 "mumbai"
GEODIST locations bangalore mumbai km             # → ~846 km
GEOPOS locations bangalore                        # → [77.5946, 12.9716]
GEOSEARCH locations FROMMEMBER bangalore BYRADIUS 500 km ASC
```

Because geo is a sorted set, `OBJECT ENCODING` on a geo key returns `skiplist` or `listpack` — and the same thresholds apply.

---

## Memory Implications of Encoding Promotions

Every encoding promotion is a one-way door — Redis never demotes back to the compact encoding once promoted, even if you delete elements to bring the count below the threshold. The only way to recover is to recreate the key.

**Quantifying the cost:**

```bash
# Hash with 128 fields, all small values
redis-cli memory usage user:session:100
# → 3072 bytes  (listpack)

# After adding the 129th field:
redis-cli memory usage user:session:100
# → 10240 bytes  (hashtable — 3× more)

# OBJECT ENCODING tells you which encoding is active:
redis-cli object encoding user:session:100
```

**The OBJECT DEBUG JMAP command** (only in DEBUG builds) dumps a memory map. For production use `MEMORY USAGE key [SAMPLES N]` — it walks the object graph sampling N elements to estimate deep sizes.

### Common promotion pitfalls

**Sorted set for leaderboard with long usernames**: if a username exceeds 64 bytes, every ZADD promotes that sorted set to skiplist immediately, regardless of member count. Score queries stay O(log N) but memory jumps.

**Hash for session objects with variable-length JSON blobs**: if a field value exceeds 64 bytes, the entire hash converts to hashtable. Many applications serialize a sub-object as a JSON blob and store it as a hash field — this is often the culprit.

**Set with one non-integer member**: if an application stores a set of user IDs (all integers) and accidentally adds a string like "guest" or "anonymous", the entire intset converts to hashtable, multiplying memory usage.

---

## Tuning Encoding Thresholds

You can raise or lower thresholds to balance memory vs CPU:

```bash
# Raise listpack threshold for hashes — use more compact encoding for longer
redis-cli config set hash-max-listpack-entries 256
redis-cli config set hash-max-listpack-value 128

# This is safe to set dynamically; existing promoted keys are not downgraded
# New keys and new writes to keys still under the old threshold will use new limits
```

**When to raise thresholds:**
- You know your objects are small and performance is not a concern.
- Memory is the primary constraint.
- Hash/set/sorted-set sizes are bounded and well-understood.

**When to lower thresholds (or leave at default):**
- Keys are large and `HGETALL` / `SMEMBERS` are called frequently — listpack scan is slower than hashtable lookup for large N.
- You have P99 latency requirements that listpack insertion (O(N)) violates.

A rough guideline: listpack is faster than hashtable for N ≤ 50 due to cache locality, slower for N > 128 due to linear scan. The defaults (128 entries) sit right at the crossover.

---

## Debugging: Unexpected Memory Growth (Encoding Promotion)

### Symptom

Redis memory grows faster than expected. The key count is stable but `used_memory` keeps climbing.

### Diagnosis

**Step 1: Find big keys**

```bash
redis-cli --bigkeys
# Scans keyspace, reports max size per type:
# Biggest string found 'raw_payload' has 1048576 bytes
# Biggest hash found   'user:session:4422' has 512 fields
# Biggest set found    'tags:product:1' has 10000 members
```

`--bigkeys` uses `SCAN` internally — safe for production, but adds read load. Alternatively, use a sample:

```bash
redis-cli --memkeys --memkeys-samples 200
```

**Step 2: Check encoding of suspicious keys**

```bash
redis-cli object encoding user:session:4422
# hashtable  <- promoted; was it supposed to be listpack?

redis-cli object freq user:session:4422      # LFU frequency counter (if maxmemory-policy lfu)
redis-cli object idletime user:session:4422  # seconds since last access
```

**Step 3: Measure memory of one key vs the whole type**

```bash
redis-cli memory usage user:session:4422 samples 0
# samples 0 = deep walk of the entire object; accurate but slow for large objects

redis-cli memory doctor
# Reports general memory health: fragmentation, repl backlog, rdb overhead, etc.
```

**Step 4: `INFO memory` holistic view**

```bash
redis-cli info memory
# used_memory:          1073741824      <- bytes in use by allocator
# used_memory_rss:      1342177280      <- bytes as seen by OS (RSS)
# mem_fragmentation_ratio: 1.25         <- RSS/used_memory; >1.5 = high fragmentation
# used_memory_peak:     1207959552      <- highest ever
# maxmemory:            2147483648      <- 0 = no limit
# mem_allocator:        libc            <- or jemalloc, tcmalloc
```

`mem_fragmentation_ratio` > 1.5 means the allocator has fragmented free space — memory is committed to the process but isn't being used efficiently. This often follows mass key deletion. Redis 4+ can actively defragment with `activedefrag yes`.

### Finding all promoted hashes

```bash
redis-cli --scan --pattern 'user:session:*' | while read key; do
  enc=$(redis-cli object encoding "$key")
  if [ "$enc" = "hashtable" ]; then
    sz=$(redis-cli memory usage "$key" samples 0)
    echo "$sz $key"
  fi
done | sort -rn | head -20
```

This scans session keys, prints size + key for any that have promoted to hashtable, sorted by size. Pipe through `sort -rn` to find the largest offenders.

---

## Debugging: Big Keys

A "big key" is one whose value is large enough to cause latency when accessed, serialized during persistence, or replicated. There is no single byte threshold — context matters.

### What makes a key "big"?

- A string value > 1 MB: serialization for RDB/replication adds I/O pressure.
- A hash/set/sorted-set with > 10,000 members: `HGETALL`, `SMEMBERS`, `ZRANGE 0 -1` will block the event loop for measurable time.
- A list with > 100,000 entries used with `LRANGE key 0 -1`.

### Mitigation strategies

| Big key type | Mitigation |
|-------------|------------|
| String > 1 MB | Compress client-side (gzip/zstd) before storing; split into chunks |
| Hash > 10K fields | Shard: `user:session:{uid}:{shard}` with a hash slot per shard |
| Set > 10K members | Paginate with SSCAN; split into time-bucketed sets |
| Sorted set > 1M members | Archive old entries periodically; use ZREMRANGEBYSCORE with LIMIT |

### Deleting big keys safely

A synchronous `DEL` on a hash with 1 million fields holds the event loop for tens of milliseconds. Always `UNLINK` (async delete) big keys:

```bash
redis-cli unlink user:session:bigkey
```

If you're on Redis < 4.0 or need DEL, do it in batches:

```bash
# Delete a large hash in batches without one big DEL
redis-cli hscan user:session:bigkey 0 count 100 | ...  # script batch HDEL
```

---

## Checkpoint

1. What encoding does Redis use for a hash with 50 fields, each with values under 64 bytes? What happens if you add a 65-byte value to field 51?
2. You have a set of 500 user IDs (all integers). What encoding is used? What happens when you add the string "guest"?
3. A sorted set encoding promotes from listpack to skiplist+hashtable. Can it ever be demoted back? How would you recover the compact encoding?
4. Why does a ZSet use BOTH a skiplist AND a hashtable? What specific operation each structure optimizes for?
5. A developer stores JSON blobs as hash field values for session objects. After a deploy, memory usage doubles. Explain what happened at the encoding level and how you'd diagnose it.
6. What does `mem_fragmentation_ratio` measure? What value signals a problem, and what is the fix?
7. For counting daily unique active users where you need to merge multiple segments (mobile, web, API), which Redis data type would you use and why? What is the memory cost at 10 million unique users?
8. A list is using the quicklist encoding with `list-compress-depth 2`. What does this mean for elements accessed at index 0 vs index 500?
9. What is the difference between `redis-cli --bigkeys` and `redis-cli memory usage key samples 0`?

→ Next up: **Persistence: RDB & AOF** — how Redis survives a restart and the exact tradeoffs between durability and performance.
