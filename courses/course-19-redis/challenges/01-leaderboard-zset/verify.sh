#!/usr/bin/env bash
# Verifier for "Leaderboard with a Sorted Set".
# Inspects the live dojo-redis container; prints the flag only when all checks pass.
set -uo pipefail

FLAG='KUBE{leaderboard_zset}'
fail() { echo "✗ $1"; exit 1; }
CLI="docker exec dojo-redis redis-cli --raw"

docker info >/dev/null 2>&1 || fail "Docker is not running"
docker ps --format '{{.Names}}' | grep -qx dojo-redis \
  || fail "dojo-redis container is not running — run setup.sh first"

# 1. Key type
KEY_TYPE=$(docker exec dojo-redis redis-cli TYPE dojo:leaderboard)
[ "$KEY_TYPE" = "zset" ] \
  || fail "dojo:leaderboard does not exist or is not a ZSET (TYPE returned: '$KEY_TYPE')"

# 2. Cardinality
ZCARD=$($CLI ZCARD dojo:leaderboard)
[ "$ZCARD" = "5" ] \
  || fail "Expected 5 members in dojo:leaderboard, got $ZCARD — add all five players"

# 3. First place (highest score) must be eve
RANK0=$($CLI ZREVRANGE dojo:leaderboard 0 0)
[ "$RANK0" = "eve" ] \
  || fail "Rank #1 (ZREVRANGE 0 0) must be 'eve' (score 9100), got '$RANK0'"

# 4. Second place must be charlie
RANK1=$($CLI ZREVRANGE dojo:leaderboard 1 1)
[ "$RANK1" = "charlie" ] \
  || fail "Rank #2 (ZREVRANGE 1 1) must be 'charlie' (score 7800), got '$RANK1'"

# 5. alice's 0-indexed rank from the top must be 2
ALICE_RANK=$($CLI ZREVRANK dojo:leaderboard alice)
[ "$ALICE_RANK" = "2" ] \
  || fail "ZREVRANK dojo:leaderboard alice must be 2 (eve=0, charlie=1, alice=2), got '$ALICE_RANK'"

# 6. eve's score must be 9100 (Redis returns float; match the prefix)
EVE_SCORE=$($CLI ZSCORE dojo:leaderboard eve)
echo "$EVE_SCORE" | grep -qE '^9100' \
  || fail "ZSCORE dojo:leaderboard eve must be 9100, got '$EVE_SCORE'"

echo
echo "All checks passed."
echo
echo "Submit this flag in the platform:"
echo
echo "    $FLAG"
