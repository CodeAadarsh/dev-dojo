#!/usr/bin/env bash
# Verifier for "Streams & Consumer Groups".
# Checks: stream non-empty, consumer group dojo-workers exists, exactly 1 PEL entry.
set -uo pipefail

FLAG='KUBE{streams_consumer_group_ack}'
fail() { echo "✗ $1"; exit 1; }

# ── 1. Container must be running ─────────────────────────────────────────────
docker exec dojo-redis redis-cli ping >/dev/null 2>&1 || \
  fail "dojo-redis container is not running — run setup.sh first"

# ── 2. Stream must exist and be non-empty ────────────────────────────────────
stream_len=$(docker exec dojo-redis redis-cli --raw XLEN dojo:events 2>/dev/null || echo 0)
[ "${stream_len:-0}" -gt 0 ] 2>/dev/null || \
  fail "Stream dojo:events is empty or missing — run setup.sh to reseed it"

# ── 3. Consumer group dojo-workers must exist on the stream ──────────────────
docker exec dojo-redis redis-cli XINFO GROUPS dojo:events 2>/dev/null \
  | grep -q "dojo-workers" || \
  fail "Consumer group 'dojo-workers' not found on dojo:events — create it with: XGROUP CREATE dojo:events dojo-workers 0"

# ── 4. Exactly 1 entry must remain in the PEL ────────────────────────────────
# XPENDING <stream> <group>  (summary form)
# With --raw, line 1 is the integer pending count; returns 0 if nothing pending.
pending=$(docker exec dojo-redis redis-cli --raw XPENDING dojo:events dojo-workers \
  2>/dev/null | head -1) || pending="0"

[ "${pending:-0}" = "1" ] || \
  fail "Expected exactly 1 pending entry in PEL, found '${pending:-0}' — XACK exactly 4 of the 5 entries (run: XPENDING dojo:events dojo-workers - + 10 to list them)"

echo "✓ Stream dojo:events exists ($stream_len entries)"
echo "✓ Consumer group 'dojo-workers' exists"
echo "✓ PEL contains exactly 1 unacknowledged entry"
echo
echo "Flag: $FLAG"
