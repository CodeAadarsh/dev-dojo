#!/usr/bin/env bash
# Ensures dojo-redis is running and seeds dojo:events with 5 events.
# Idempotent: deletes any existing consumer groups and re-seeds the stream.
set -euo pipefail

echo "==> Ensuring dojo-redis container is running..."
docker ps -a --format '{{.Names}}' | grep -qx dojo-redis || \
  docker run -d --name dojo-redis -p 6399:6379 redis:7-alpine

echo "==> Waiting for Redis to accept connections..."
until docker exec dojo-redis redis-cli ping >/dev/null 2>&1; do sleep 1; done

SLUG="04-streams-consumer-group"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

echo "==> Seeding stream dojo:events with 5 events (idempotent)..."

# Delete the stream entirely so any previous group/PEL state is gone
docker exec dojo-redis redis-cli DEL dojo:events > /dev/null

# XADD with * lets Redis assign timestamp-based IDs automatically
docker exec dojo-redis redis-cli XADD dojo:events '*' \
  event_type order_placed order_id ORD-1001 product widget-a qty 3 user_id U-42 > /dev/null

docker exec dojo-redis redis-cli XADD dojo:events '*' \
  event_type order_placed order_id ORD-1002 product gadget-b qty 1 user_id U-17 > /dev/null

docker exec dojo-redis redis-cli XADD dojo:events '*' \
  event_type order_shipped order_id ORD-1001 carrier fedex tracking_id TRK-555 > /dev/null

docker exec dojo-redis redis-cli XADD dojo:events '*' \
  event_type order_placed order_id ORD-1003 product widget-a qty 5 user_id U-99 > /dev/null

docker exec dojo-redis redis-cli XADD dojo:events '*' \
  event_type order_cancelled order_id ORD-1002 reason out_of_stock > /dev/null

stream_len=$(docker exec dojo-redis redis-cli XLEN dojo:events)

echo "==> Scaffolding work file..."
cat > "$WORK/commands.sh" << 'SHEOF'
#!/usr/bin/env bash
# Streams Consumer Group — fill-in-the-blanks work file
# Redis is at localhost:6399.
# Connect directly:  redis-cli -h localhost -p 6399
# Or via Docker:     docker exec -it dojo-redis redis-cli

# ── STEP 1: Inspect the seeded stream ───────────────────────────────────────
# Note the 5 entry IDs (format: <timestamp-ms>-<seq>).  You will need 4 of them
# for the XACK call in STEP 5.
docker exec dojo-redis redis-cli XRANGE dojo:events - +

# ── STEP 2: Create the consumer group ───────────────────────────────────────
# '0' means start-from the very first entry in the stream (deliver all history).
# Use '$' instead of '0' if you only want future entries.
docker exec dojo-redis redis-cli XGROUP CREATE dojo:events dojo-workers 0

# ── STEP 3: Read all 5 messages as consumer worker-1 ────────────────────────
# '>' is the special cursor: "entries not yet delivered to any consumer in this group"
# After this call, all 5 IDs appear in the PEL.
docker exec dojo-redis redis-cli XREADGROUP GROUP dojo-workers worker-1 \
    COUNT 10 STREAMS dojo:events ">"

# ── STEP 4: List the PEL to confirm all 5 are pending ───────────────────────
docker exec dojo-redis redis-cli XPENDING dojo:events dojo-workers - + 10

# ── STEP 5: ACK exactly 4 entries — leave 1 unacked ─────────────────────────
# Copy 4 of the 5 IDs from STEP 4 and substitute below.
# docker exec dojo-redis redis-cli XACK dojo:events dojo-workers \
#   <id1> <id2> <id3> <id4>

# ── STEP 6: Confirm exactly 1 remains in PEL ────────────────────────────────
docker exec dojo-redis redis-cli XPENDING dojo:events dojo-workers
SHEOF

chmod +x "$WORK/commands.sh"

echo
echo "Stream         : dojo:events ($stream_len entries seeded)"
echo "Work directory : $WORK"
echo "Work file      : $WORK/commands.sh"
echo
echo "Next steps:"
echo "  1. Open and read $WORK/commands.sh"
echo "  2. Run each step in order, filling in the 4 IDs in STEP 5"
echo "  3. Verify: bash courses/course-19-redis/challenges/04-streams-consumer-group/verify.sh"
