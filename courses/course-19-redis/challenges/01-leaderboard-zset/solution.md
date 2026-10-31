# Solution — Leaderboard with a Sorted Set

The flag is `KUBE{leaderboard_zset}`.

## The minimal commands

Connect interactively:

```bash
docker exec -it dojo-redis redis-cli
```

Inside the shell:

```
ZADD dojo:leaderboard 5000 alice 3200 bob 7800 charlie 4500 diana 9100 eve
ZREVRANGE dojo:leaderboard 0 -1 WITHSCORES
ZREVRANK dojo:leaderboard alice
ZSCORE dojo:leaderboard eve
```

Or as a one-liner from the host:

```bash
docker exec dojo-redis redis-cli ZADD dojo:leaderboard \
  5000 alice 3200 bob 7800 charlie 4500 diana 9100 eve
```

The expected output of `ZREVRANGE ... 0 -1 WITHSCORES`:

```
eve
9100
charlie
7800
alice
5000
diana
4500
bob
3200
```

`ZREVRANK alice` returns `2` — eve is rank 0, charlie rank 1, alice rank 2.

## Why all five members in one ZADD call

Each `ZADD key score member` argument pair is processed atomically in the skip-list. Sending all five in one command is a single round trip and a single write pass through the data structure — semantically equivalent to five separate calls but faster and idempotent in tests. It also keeps the key consistent: a partial ZADD (three members loaded, process crashes) leaves a key that partially passes the verifier.

## Reading the leaderboard — full command reference

| Command | What it returns |
|---------|-----------------|
| `ZREVRANGE key 0 -1` | All members, highest score first |
| `ZREVRANGE key 0 -1 WITHSCORES` | Same, interleaved with scores |
| `ZREVRANGE key 0 9` | Top 10 |
| `ZRANGEBYSCORE key -inf +inf` | All members, lowest score first |
| `ZREVRANGEBYSCORE key +inf 5000` | All members scoring ≥ 5000, highest first |
| `ZREVRANK key alice` | alice's rank, 0-indexed from the top |
| `ZRANK key alice` | alice's rank, 0-indexed from the bottom |
| `ZSCORE key alice` | alice's raw score as a float string |
| `ZINCRBY key 100 alice` | Increment alice's score by 100 (atomic) |
| `ZCARD key` | Total member count |
| `ZCOUNT key 4000 9000` | Members with score in [4000, 9000] |

## Score tie-breaking

Scores are stored as IEEE 754 float64. When two members have identical scores, Redis sorts them lexicographically by member name within that tie. If alice and diana both had 5000:

```
ZADD dojo:leaderboard 5000 alice 5000 diana
ZREVRANGE dojo:leaderboard 0 -1
# diana  (d > a lexicographically, so diana ranks higher within the tie)
# alice
```

This is a frequent source of bugs in ranked leaderboards — if you need strict FIFO tie-breaking (first to reach 5000 ranks higher), store a tiebreak in the score: `score = base_score * 1e9 + (max_timestamp - event_timestamp)`.

## Updating scores efficiently

```bash
# Single update
docker exec dojo-redis redis-cli ZINCRBY dojo:leaderboard 250 alice
# alice now has 5250

# Bulk update from a file of "score member" pairs
while read score member; do
  docker exec dojo-redis redis-cli ZINCRBY dojo:leaderboard "$score" "$member"
done < delta_scores.txt
```

For high-throughput updates, pipeline or batch ZINCRBY calls — each round trip to Docker adds ~0.5ms latency on a local machine, but in a container-to-container call over a real network it can be 1–5ms.

## Production pattern

A real-time leaderboard in production:

```
Game event → ZINCRBY dojo:leaderboard <points> <player_id>  (Redis write, ~1ms)
             INSERT INTO score_events (player_id, delta, ts) VALUES (...)  (Postgres async)

Leaderboard page → ZREVRANGE dojo:leaderboard 0 99 WITHSCORES  (Redis read, ~1ms)
                   SELECT name, avatar FROM players WHERE id IN (...)  (Postgres by PK)
```

Redis never stores names or avatars — only the numeric score keyed by player ID. Postgres is the source of truth; Redis is the sorted index. A periodic reconciliation job (e.g. nightly) rewrites the ZSET from Postgres to correct any drift from process crashes mid-pipeline.
