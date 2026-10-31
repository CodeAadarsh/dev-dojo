#!/usr/bin/env bash
# Verifier for "Distributed Lock with Lua Release".
# Runs acquire/release sequences; asserts exact pass/fail behavior at each step.
set -uo pipefail

FLAG='KUBE{distributed_lock_nx_lua}'
WORK="$HOME/.kube-dojo-work/03-distributed-lock"
fail() { echo "✗ $1"; exit 1; }

docker info >/dev/null 2>&1 || fail "Docker is not running"
docker ps --format '{{.Names}}' | grep -qx dojo-redis \
  || fail "dojo-redis container is not running — run setup.sh first"
[ -f "$WORK/acquire.sh" ] \
  || fail "acquire.sh not found in $WORK — run setup.sh first"
[ -f "$WORK/release.sh" ] \
  || fail "release.sh not found in $WORK — run setup.sh first"

LOCK="lock:dojo"

# ── Step 0: clean state ────────────────────────────────────────────────────
docker exec dojo-redis redis-cli DEL "$LOCK" >/dev/null

# ── Step 1: acquire with token-alice must succeed ─────────────────────────
bash "$WORK/acquire.sh" "$LOCK" token-alice 30000 >/dev/null \
  || fail "acquire.sh lock:dojo token-alice 30000 should exit 0 (lock is free), but it exited non-zero"

EXISTS=$(docker exec dojo-redis redis-cli --raw EXISTS "$LOCK")
[ "$EXISTS" = "1" ] \
  || fail "lock:dojo must exist in Redis after a successful acquire, got EXISTS=$EXISTS"

STORED=$(docker exec dojo-redis redis-cli --raw GET "$LOCK")
[ "$STORED" = "token-alice" ] \
  || fail "lock:dojo must hold the value 'token-alice', got '$STORED'"

# ── Step 2: second acquire with token-bob must fail ───────────────────────
if bash "$WORK/acquire.sh" "$LOCK" token-bob 30000 >/dev/null 2>&1; then
  fail "acquire.sh lock:dojo token-bob should exit 1 (lock already held by token-alice), but it exited 0"
fi

# Alice's token must still be intact — bob must not have overwritten it
STORED=$(docker exec dojo-redis redis-cli --raw GET "$LOCK")
[ "$STORED" = "token-alice" ] \
  || fail "lock:dojo must still hold 'token-alice' after bob's failed acquire, got '$STORED'"

# ── Step 3: release with wrong token must be rejected ─────────────────────
if bash "$WORK/release.sh" "$LOCK" wrong-token >/dev/null 2>&1; then
  fail "release.sh lock:dojo wrong-token should exit 1 (token mismatch), but it exited 0"
fi

EXISTS=$(docker exec dojo-redis redis-cli --raw EXISTS "$LOCK")
[ "$EXISTS" = "1" ] \
  || fail "lock:dojo must still exist after a wrong-token release attempt, got EXISTS=$EXISTS"

# ── Step 4: release with correct token must succeed ───────────────────────
bash "$WORK/release.sh" "$LOCK" token-alice >/dev/null \
  || fail "release.sh lock:dojo token-alice should exit 0 (correct token), but it exited non-zero"

EXISTS=$(docker exec dojo-redis redis-cli --raw EXISTS "$LOCK")
[ "$EXISTS" = "0" ] \
  || fail "lock:dojo must not exist after a correct release, got EXISTS=$EXISTS"

echo
echo "All checks passed:"
echo "  acquire (free lock)    -> ACQUIRED  [ok]"
echo "  acquire (held lock)    -> FAILED    [ok]"
echo "  release (wrong token)  -> NOT_OWNER [ok]"
echo "  release (right token)  -> RELEASED  [ok]"
echo
echo "Submit this flag in the platform:"
echo
echo "    $FLAG"
