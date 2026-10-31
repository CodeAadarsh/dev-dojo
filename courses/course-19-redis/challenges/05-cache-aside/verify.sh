#!/usr/bin/env bash
# Verifier for "Cache-Aside Pattern".
# Checks: all 3 cache keys exist AND each has a positive TTL.
set -uo pipefail

FLAG='KUBE{cache_aside_ttl_hit}'
fail() { echo "✗ $1"; exit 1; }

# ── 1. Container must be running ─────────────────────────────────────────────
docker exec dojo-redis redis-cli ping >/dev/null 2>&1 || \
  fail "dojo-redis container is not running — run setup.sh first"

# ── 2. Source of truth hash must still be intact ─────────────────────────────
sot_len=$(docker exec dojo-redis redis-cli --raw HLEN dojo:sot 2>/dev/null || echo 0)
[ "${sot_len:-0}" -gt 0 ] 2>/dev/null || \
  fail "Source hash dojo:sot is missing — run setup.sh to reseed it"

# ── 3. All 3 cache keys must exist with a TTL > 0 ────────────────────────────
for i in 1 2 3; do
  key="dojo:cache:product:$i"

  exists=$(docker exec dojo-redis redis-cli --raw EXISTS "$key" 2>/dev/null || echo 0)
  [ "${exists:-0}" = "1" ] || \
    fail "Cache key '$key' not found — implement the miss path: HGET dojo:sot product:$i then SET $key <value> EX <seconds>"

  ttl=$(docker exec dojo-redis redis-cli --raw TTL "$key" 2>/dev/null || echo -2)
  [ "${ttl:--2}" -gt 0 ] 2>/dev/null || \
    fail "Cache key '$key' exists but TTL is '${ttl:--2}' (expected > 0) — use SET $key <value> EX <seconds> to set an expiry"

  echo "✓ dojo:cache:product:$i exists (TTL=${ttl}s)"
done

echo
echo "Flag: $FLAG"
