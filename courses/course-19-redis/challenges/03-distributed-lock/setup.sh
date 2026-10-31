#!/usr/bin/env bash
# Plants the "Distributed Lock with Lua Release" starter scripts.
# Idempotent — re-running rewrites the starters and clears lock:dojo.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/03-distributed-lock"
mkdir -p "$WORK"

# Ensure dojo-redis container is running
docker ps -a --format '{{.Names}}' | grep -qx dojo-redis || \
  docker run -d --name dojo-redis -p 6399:6379 redis:7-alpine

until docker exec dojo-redis redis-cli ping >/dev/null 2>&1; do sleep 1; done
echo "dojo-redis is ready."

# Clean up any leftover lock
docker exec dojo-redis redis-cli DEL lock:dojo >/dev/null

# ── acquire.sh ───────────────────────────────────────────────────────────────
cat > "$WORK/acquire.sh" << 'SHEOF'
#!/usr/bin/env bash
# acquire.sh — acquire a distributed lock
# Usage: bash acquire.sh <key> <token> <ttl_ms>
# Prints ACQUIRED (exit 0) on success, FAILED (exit 1) if already held.
#
# The SET command with NX and PX is an atomic test-and-set:
#   SET <key> <token> NX PX <ttl_ms>
#   Returns "OK" if acquired, empty/nil if the key already exists (lock held).
set -euo pipefail

KEY="${1:?Usage: acquire.sh <key> <token> <ttl_ms>}"
TOKEN="${2:?acquire.sh: token required}"
TTL="${3:?acquire.sh: ttl_ms required}"

# TODO: Run:  docker exec dojo-redis redis-cli SET "$KEY" "$TOKEN" NX PX "$TTL"
# Capture the result. "OK" means acquired; anything else means the lock is held.
# Print ACQUIRED + exit 0, or FAILED + exit 1.

echo "FAILED"
exit 1
SHEOF
chmod +x "$WORK/acquire.sh"

# ── release.sh ───────────────────────────────────────────────────────────────
cat > "$WORK/release.sh" << 'SHEOF'
#!/usr/bin/env bash
# release.sh — release a distributed lock (safe, Lua-based)
# Usage: bash release.sh <key> <token>
# Prints RELEASED (exit 0) if token matched; NOT_OWNER (exit 1) if mismatch.
#
# A plain DEL is WRONG — it deletes the key even if a different holder owns it.
# The correct release is an atomic compare-and-delete via Lua:
#
#   Lua script:
#     if redis.call("GET", KEYS[1]) == ARGV[1] then
#       return redis.call("DEL", KEYS[1])
#     else
#       return 0
#     end
#
#   Execute with:
#     docker exec dojo-redis redis-cli EVAL \
#       "if redis.call('GET',KEYS[1])==ARGV[1] then return redis.call('DEL',KEYS[1]) else return 0 end" \
#       1 "$KEY" "$TOKEN"
#
#   Returns 1 if deleted, 0 if token mismatch.
set -euo pipefail

KEY="${1:?Usage: release.sh <key> <token>}"
TOKEN="${2:?release.sh: token required}"

# TODO: Run the EVAL command above with $KEY and $TOKEN.
# If the result is "1", print RELEASED and exit 0.
# If the result is "0", print NOT_OWNER and exit 1.

echo "NOT_OWNER"
exit 1
SHEOF
chmod +x "$WORK/release.sh"

echo
echo "Work directory : $WORK"
echo "Scripts        : $WORK/acquire.sh"
echo "               : $WORK/release.sh"
echo
echo "Next steps:"
echo "  1. Implement acquire.sh (SET NX PX) and release.sh (EVAL Lua script)."
echo "  2. Test manually:"
echo "     bash $WORK/acquire.sh lock:dojo my-token 30000   # should print ACQUIRED"
echo "     bash $WORK/acquire.sh lock:dojo other 30000      # should print FAILED"
echo "     bash $WORK/release.sh lock:dojo wrong-token      # should print NOT_OWNER"
echo "     bash $WORK/release.sh lock:dojo my-token         # should print RELEASED"
echo "  3. Run the verifier: bash courses/course-19-redis/challenges/03-distributed-lock/verify.sh"
