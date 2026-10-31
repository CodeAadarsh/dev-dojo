#!/usr/bin/env bash
# Verifier for "Fixed-Window Rate Limiter".
# Calls rate_limiter.sh 7 times; asserts exactly 5 ALLOWED then 2 BLOCKED, with TTL set.
set -uo pipefail

FLAG='KUBE{rate_limiter_incr_expire}'
WORK="$HOME/.kube-dojo-work/02-rate-limiter"
LIMIT=5
fail() { echo "✗ $1"; exit 1; }

docker info >/dev/null 2>&1 || fail "Docker is not running"
docker ps --format '{{.Names}}' | grep -qx dojo-redis \
  || fail "dojo-redis container is not running — run setup.sh first"
[ -f "$WORK/rate_limiter.sh" ] \
  || fail "rate_limiter.sh not found in $WORK — run setup.sh first"

# Use a unique test user so concurrent runs don't interfere
TEST_USER="verify-$$"
KEY="rate:$TEST_USER"

# Clean slate for the test window
docker exec dojo-redis redis-cli DEL "$KEY" >/dev/null

ALLOWED=0
BLOCKED=0
UNEXPECTED=0

for i in $(seq 1 $((LIMIT + 2))); do
  RESULT=$(bash "$WORK/rate_limiter.sh" "$TEST_USER" 2>/dev/null)
  case "$RESULT" in
    ALLOWED) ALLOWED=$((ALLOWED + 1)) ;;
    BLOCKED) BLOCKED=$((BLOCKED + 1)) ;;
    *)       UNEXPECTED=$((UNEXPECTED + 1))
             echo "  Request $i returned unexpected output: '$RESULT'" ;;
  esac
done

[ "$UNEXPECTED" = "0" ] \
  || fail "rate_limiter.sh produced $UNEXPECTED unexpected output(s) — it must print exactly ALLOWED or BLOCKED"

[ "$ALLOWED" = "$LIMIT" ] \
  || fail "Expected exactly $LIMIT ALLOWED responses, got $ALLOWED (first $LIMIT requests must be allowed)"

[ "$BLOCKED" = "2" ] \
  || fail "Expected exactly 2 BLOCKED responses after the limit, got $BLOCKED"

# Verify the key has a positive TTL (EXPIRE was applied)
TTL=$(docker exec dojo-redis redis-cli --raw TTL "$KEY")
case "$TTL" in
  -2) fail "Key $KEY does not exist — INCR was never called, or the window already expired" ;;
  -1) fail "Key $KEY exists but has no TTL — EXPIRE NX was not applied" ;;
  *)
    if ! [ "$TTL" -gt 0 ] 2>/dev/null; then
      fail "TTL $KEY returned unexpected value: '$TTL'"
    fi
    ;;
esac

# Cleanup
docker exec dojo-redis redis-cli DEL "$KEY" >/dev/null

echo
echo "All checks passed: $ALLOWED allowed, 2 blocked, TTL = ${TTL}s."
echo
echo "Submit this flag in the platform:"
echo
echo "    $FLAG"
