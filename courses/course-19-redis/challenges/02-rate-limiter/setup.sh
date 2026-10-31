#!/usr/bin/env bash
# Plants the "Fixed-Window Rate Limiter" starter script.
# Idempotent — re-running rewrites the starter but does not wipe existing rate keys.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/02-rate-limiter"
mkdir -p "$WORK"

# Ensure dojo-redis container is running
docker ps -a --format '{{.Names}}' | grep -qx dojo-redis || \
  docker run -d --name dojo-redis -p 6399:6379 redis:7-alpine

until docker exec dojo-redis redis-cli ping >/dev/null 2>&1; do sleep 1; done
echo "dojo-redis is ready."

# Plant the starter script — learner implements the body
cat > "$WORK/rate_limiter.sh" << 'SHEOF'
#!/usr/bin/env bash
# rate_limiter.sh — fixed-window rate limiter
# Usage: bash rate_limiter.sh <user_id>
# Outputs ALLOWED (exit 0) or BLOCKED (exit 1).
#
# Rules:
#   Limit  : 5 requests per window
#   Window : 60 seconds
#   Key    : rate:<user_id>
#   Pattern: INCR + EXPIRE NX
set -euo pipefail

USER_ID="${1:?Usage: rate_limiter.sh <user_id>}"
LIMIT=5
WINDOW=60
KEY="rate:$USER_ID"

# Step 1: Atomically increment the per-user counter.
#   COUNT=$(docker exec dojo-redis redis-cli INCR "$KEY")
#
# Step 2: Set the TTL only if no TTL exists yet (NX flag, Redis 7+).
#   docker exec dojo-redis redis-cli EXPIRE "$KEY" $WINDOW NX >/dev/null
#
# Step 3: Allow if count <= LIMIT, block otherwise.
#   if [ "$COUNT" -le "$LIMIT" ]; then echo "ALLOWED"; exit 0
#   else echo "BLOCKED"; exit 1; fi

# TODO: Implement the three steps above. Remove this stub.
echo "BLOCKED"
exit 1
SHEOF
chmod +x "$WORK/rate_limiter.sh"

echo
echo "Work directory : $WORK"
echo "Starter script : $WORK/rate_limiter.sh"
echo
echo "Next steps:"
echo "  1. Edit $WORK/rate_limiter.sh — implement the three steps in the comments."
echo "  2. Test manually:  bash $WORK/rate_limiter.sh testuser"
echo "     (run it 7 times; first 5 should print ALLOWED, last 2 BLOCKED)"
echo "  3. Run the verifier: bash courses/course-19-redis/challenges/02-rate-limiter/verify.sh"
echo
echo "Tip: DEL a key with:  docker exec dojo-redis redis-cli DEL rate:testuser"
