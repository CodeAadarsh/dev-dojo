#!/usr/bin/env bash
# Ensures dojo-redis is running and seeds the source-of-truth hash dojo:sot.
# Idempotent: deletes and reseeds the source hash, and removes any old cache keys.
set -euo pipefail

echo "==> Ensuring dojo-redis container is running..."
docker ps -a --format '{{.Names}}' | grep -qx dojo-redis || \
  docker run -d --name dojo-redis -p 6399:6379 redis:7-alpine

echo "==> Waiting for Redis to accept connections..."
until docker exec dojo-redis redis-cli ping >/dev/null 2>&1; do sleep 1; done

SLUG="05-cache-aside"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

echo "==> Seeding source-of-truth hash dojo:sot..."

# Remove any previous state so the challenge is reproducible
docker exec dojo-redis redis-cli DEL dojo:sot \
    dojo:cache:product:1 dojo:cache:product:2 dojo:cache:product:3 > /dev/null

# Seed the source hash — three products as pipe-delimited "name|price|category"
docker exec dojo-redis redis-cli HSET dojo:sot \
  product:1 "Widget|9.99|tools" \
  product:2 "Gadget|14.99|electronics" \
  product:3 "Doohickey|4.99|misc" > /dev/null

echo "==> Scaffolding work file..."
cat > "$WORK/commands.sh" << 'SHEOF'
#!/usr/bin/env bash
# Cache-Aside Pattern — work file
# Redis is at localhost:6399.
# Source of truth: HGET dojo:sot product:{1..3}
# Cache keys:      dojo:cache:product:{1..3}  (you create these)

# ── Inspect the source of truth ─────────────────────────────────────────────
docker exec dojo-redis redis-cli HGETALL dojo:sot

# ── MISS path: check, read, populate ────────────────────────────────────────
# 1. Check: 0 = miss
docker exec dojo-redis redis-cli EXISTS dojo:cache:product:1

# 2. Read from source (simulates the expensive DB call)
docker exec dojo-redis redis-cli HGET dojo:sot product:1

# 3. Populate cache with TTL (value copied from HGET output above)
docker exec dojo-redis redis-cli SET dojo:cache:product:1 "Widget|9.99|tools" EX 60

# Repeat for products 2 and 3 ────────────────────────────────────────────────
docker exec dojo-redis redis-cli SET dojo:cache:product:2 "Gadget|14.99|electronics" EX 60
docker exec dojo-redis redis-cli SET dojo:cache:product:3 "Doohickey|4.99|misc" EX 60

# ── HIT path: check, read from cache ────────────────────────────────────────
# 1. Check: 1 = hit (key is now present)
docker exec dojo-redis redis-cli EXISTS dojo:cache:product:1

# 2. Serve from cache (no source read needed)
docker exec dojo-redis redis-cli GET dojo:cache:product:1

# ── Confirm TTLs are set ─────────────────────────────────────────────────────
docker exec dojo-redis redis-cli TTL dojo:cache:product:1
docker exec dojo-redis redis-cli TTL dojo:cache:product:2
docker exec dojo-redis redis-cli TTL dojo:cache:product:3
SHEOF

chmod +x "$WORK/commands.sh"

echo
echo "Source hash    : dojo:sot (3 products seeded)"
echo "Cache keys     : dojo:cache:product:{1,2,3} — you create these"
echo "Work directory : $WORK"
echo "Work file      : $WORK/commands.sh"
echo
echo "Next steps:"
echo "  1. Run commands from $WORK/commands.sh step by step"
echo "  2. Verify: bash courses/course-19-redis/challenges/05-cache-aside/verify.sh"
