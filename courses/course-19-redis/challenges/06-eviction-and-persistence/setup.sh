#!/usr/bin/env bash
# Ensures dojo-redis is running and resets config to defaults so the challenge
# always starts from a known state.
set -euo pipefail

echo "==> Ensuring dojo-redis container is running..."
docker ps -a --format '{{.Names}}' | grep -qx dojo-redis || \
  docker run -d --name dojo-redis -p 6399:6379 redis:7-alpine

echo "==> Waiting for Redis to accept connections..."
until docker exec dojo-redis redis-cli ping >/dev/null 2>&1; do sleep 1; done

echo "==> Resetting config to defaults (idempotent)..."
# Return to the default state so re-running gives a clean start
docker exec dojo-redis redis-cli CONFIG SET maxmemory 0 > /dev/null
docker exec dojo-redis redis-cli CONFIG SET maxmemory-policy noeviction > /dev/null
docker exec dojo-redis redis-cli CONFIG SET appendonly no > /dev/null

SLUG="06-eviction-and-persistence"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

echo "==> Scaffolding work file..."
cat > "$WORK/commands.sh" << 'SHEOF'
#!/usr/bin/env bash
# Eviction Policy & AOF Persistence — work file
# All three CONFIG SET calls below are the solution.
# Run them one at a time and check the CONFIG GET output to understand the effect.

# ── INSPECT DEFAULTS ────────────────────────────────────────────────────────
docker exec dojo-redis redis-cli CONFIG GET maxmemory
docker exec dojo-redis redis-cli CONFIG GET maxmemory-policy
docker exec dojo-redis redis-cli CONFIG GET appendonly

# ── STEP 1: Set a memory ceiling ────────────────────────────────────────────
# Accepts human-readable units: kb, mb, gb. Or raw bytes (104857600 = 100mb).
docker exec dojo-redis redis-cli CONFIG SET maxmemory 100mb

# ── STEP 2: Evict least recently used keys across all keys ──────────────────
docker exec dojo-redis redis-cli CONFIG SET maxmemory-policy allkeys-lru

# ── STEP 3: Enable AOF persistence ──────────────────────────────────────────
docker exec dojo-redis redis-cli CONFIG SET appendonly yes

# ── VERIFY MANUALLY ─────────────────────────────────────────────────────────
docker exec dojo-redis redis-cli CONFIG GET maxmemory
docker exec dojo-redis redis-cli CONFIG GET maxmemory-policy
docker exec dojo-redis redis-cli CONFIG GET appendonly

# Full persistence info (check aof_enabled, aof_rewrite_in_progress, etc.)
docker exec dojo-redis redis-cli INFO persistence
SHEOF

chmod +x "$WORK/commands.sh"

echo
echo "Config reset   : maxmemory=0, maxmemory-policy=noeviction, appendonly=no"
echo "Work directory : $WORK"
echo "Work file      : $WORK/commands.sh"
echo
echo "Your task: apply three CONFIG SET commands — run from $WORK/commands.sh"
echo "Verify: bash courses/course-19-redis/challenges/06-eviction-and-persistence/verify.sh"
