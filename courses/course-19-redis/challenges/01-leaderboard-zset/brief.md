# Leaderboard with a Sorted Set

Your team ships a multiplayer game. The product manager's Slack message arrives at 9 am: *"The leaderboard takes 4 seconds to render. The query scans the entire `users` table, sorts it in application memory, and returns the top 10. Peak MAU traffic starts in 30 minutes."*

The fix is not a Postgres index. The wrong data structure is the root cause. A relational table is an unordered bag of rows; producing a ranked view requires O(n log n) work on every read. A Redis **Sorted Set** (ZSET) stores members paired with floating-point scores and maintains sort order as part of the data structure itself — O(log n) writes, O(log n + result_size) reads for any rank query regardless of total member count. Leaderboards, priority queues, rate-limiter sliding windows, and job scheduling queues are all ZSET problems.

## Prerequisites

**Docker must be running.** `setup.sh` starts a `dojo-redis` container on host port **6399** if one is not already present.

## Mission

Populate the key `dojo:leaderboard` as a ZSET with the following five players and scores, then confirm the read queries match the expected values.

| Player  | Score |
|---------|-------|
| alice   | 5000  |
| bob     | 3200  |
| charlie | 7800  |
| diana   | 4500  |
| eve     | 9100  |

The verifier asserts **all five** of the following:

1. `TYPE dojo:leaderboard` is `zset`.
2. `ZCARD dojo:leaderboard` returns `5`.
3. `ZREVRANGE dojo:leaderboard 0 0` (first place) is `eve`.
4. `ZREVRANGE dojo:leaderboard 1 1` (second place) is `charlie`.
5. `ZREVRANK dojo:leaderboard alice` returns `2` (0-indexed from the top).
6. `ZSCORE dojo:leaderboard eve` returns `9100`.

> **Rank arithmetic.** ZREVRANK is 0-indexed from the highest score: `eve` at 9100 is rank 0, `charlie` at 7800 is rank 1, `alice` at 5000 is rank 2. If a player is not in the ZSET, ZREVRANK returns a nil/empty string — the verifier will fail with a clear message telling you which check broke.

## How to start

`setup.sh` places a starter script in your work directory and clears any previous leaderboard state for a clean run:

```bash
bash courses/course-19-redis/challenges/01-leaderboard-zset/setup.sh
```

Edit the starter script:

```bash
cat ~/.kube-dojo-work/01-leaderboard-zset/commands.sh
# fill in the ZADD line with all five players
```

Apply your commands:

```bash
bash ~/.kube-dojo-work/01-leaderboard-zset/commands.sh
```

Or run commands interactively:

```bash
docker exec -it dojo-redis redis-cli
```

Then verify:

```bash
bash courses/course-19-redis/challenges/01-leaderboard-zset/verify.sh
```

## Why a ZSET beats a sorted column

A relational `ORDER BY score DESC LIMIT 10` re-sorts on every read — O(n log n) across all rows unless covered by an index, and even with an index the planner still reads N index entries to return 10 rows. A ZSET skip-list maintains order on every **write**, so `ZREVRANGE 0 9` is O(log n + 10) regardless of whether you have 100 members or 10 million.

The trade-off: a ZSET stores one score per member and nothing else. Production leaderboards pair Redis with Postgres:

```
Write path:  game server -> ZINCRBY dojo:leaderboard <delta> <player>
Read path:   ZREVRANGE dojo:leaderboard 0 99          (top 100, microseconds)
             SELECT * FROM players WHERE id IN (...)   (profile enrichment)
```

The ZSET handles rank; Postgres handles everything else. Redis never becomes the system of record.
