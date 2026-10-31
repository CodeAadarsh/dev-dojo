#!/usr/bin/env bash
# Verifier: "Isolation Anomaly — Prevent the Lost Update"
# Resets the account balance to 0, runs fix.sql TWICE CONCURRENTLY, then
# asserts the final balance is 1000 (both additions serialized, no lost update).
# Prints the flag only when the invariant holds.
set -uo pipefail

SLUG="02-isolation-anomaly"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{isolation_prevents_lost_update}'

fail() { echo "✗ $1"; exit 1; }

echo "==> Checking dojo-pg container is running..."
docker ps --format '{{.Names}}' | grep -qx dojo-pg \
  || fail "dojo-pg is not running — run setup.sh first"

echo "==> Checking accounts table exists..."
TBL=$(docker exec dojo-pg psql -U postgres -d dojo -tA -c \
  "SELECT COUNT(*) FROM pg_class c
   JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relname = 'accounts' AND n.nspname = 'public';" | tr -d '[:space:]')
[ "$TBL" -ge 1 ] 2>/dev/null \
  || fail "table 'accounts' not found — run setup.sh first"

echo "==> Checking fix.sql exists in work directory..."
[ -f "$WORK/fix.sql" ] \
  || fail "fix.sql not found at $WORK/fix.sql — run setup.sh first"

echo "==> Resetting account balance to 0 for a clean test..."
docker exec dojo-pg psql -U postgres -d dojo -q \
  -c "UPDATE accounts SET balance = 0 WHERE id = 1;" >/dev/null

echo "==> Running two concurrent transactions (takes ~0.5 s)..."
# Both sessions execute fix.sql simultaneously. With the lost-update bug
# (no FOR UPDATE), both read 0, sleep 0.2 s, then both write 500 — final=500.
# With FOR UPDATE, the second session blocks until the first commits (balance=500),
# then reads 500 and writes 1000 — final=1000. That is the only passing state.
docker exec -i dojo-pg psql -U postgres -d dojo < "$WORK/fix.sql" >/dev/null &
PID1=$!
sleep 0.1
docker exec -i dojo-pg psql -U postgres -d dojo < "$WORK/fix.sql" >/dev/null &
PID2=$!
wait $PID1 $PID2

echo "==> Checking final balance (must equal 1000)..."
BALANCE=$(docker exec dojo-pg psql -U postgres -d dojo -tA \
  -c "SELECT balance::int FROM accounts WHERE id = 1;" | tr -d '[:space:]')
[ "$BALANCE" = "1000" ] \
  || fail "lost update detected — final balance is $BALANCE (expected 1000). Add FOR UPDATE to the SELECT line in fix.sql."

echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
