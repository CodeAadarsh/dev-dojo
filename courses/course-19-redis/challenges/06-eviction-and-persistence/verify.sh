#!/usr/bin/env bash
# Verifier for "Eviction Policy & AOF Persistence".
# Checks: maxmemory-policy == allkeys-lru, maxmemory > 0, appendonly == yes.
set -uo pipefail

FLAG='KUBE{eviction_and_persistence_config}'
fail() { echo "✗ $1"; exit 1; }

# ── 1. Container must be running ─────────────────────────────────────────────
docker exec dojo-redis redis-cli ping >/dev/null 2>&1 || \
  fail "dojo-redis container is not running — run setup.sh first"

# ── 2. Eviction policy must be allkeys-lru ───────────────────────────────────
# CONFIG GET maxmemory-policy with --raw returns two lines: key then value.
# tail -1 extracts the value.
policy=$(docker exec dojo-redis redis-cli --raw CONFIG GET maxmemory-policy \
  2>/dev/null | tail -1) || policy=""

[ "${policy:-}" = "allkeys-lru" ] || \
  fail "maxmemory-policy is '${policy:-unset}', expected 'allkeys-lru' — run: CONFIG SET maxmemory-policy allkeys-lru"

# ── 3. maxmemory must be > 0 (i.e. a finite ceiling is set) ──────────────────
# CONFIG GET maxmemory always returns bytes as an integer.
maxmem=$(docker exec dojo-redis redis-cli --raw CONFIG GET maxmemory \
  2>/dev/null | tail -1) || maxmem="0"

[ "${maxmem:-0}" -gt 0 ] 2>/dev/null || \
  fail "maxmemory is '${maxmem:-0}' (unlimited) — set a finite ceiling, e.g.: CONFIG SET maxmemory 100mb"

# ── 4. AOF must be enabled ────────────────────────────────────────────────────
aof=$(docker exec dojo-redis redis-cli --raw CONFIG GET appendonly \
  2>/dev/null | tail -1) || aof=""

[ "${aof:-}" = "yes" ] || \
  fail "appendonly is '${aof:-no}', expected 'yes' — run: CONFIG SET appendonly yes"

echo "✓ maxmemory-policy = allkeys-lru"
echo "✓ maxmemory = ${maxmem} bytes ($(( maxmem / 1048576 )) MiB ceiling)"
echo "✓ appendonly = yes"
echo
echo "Flag: $FLAG"
