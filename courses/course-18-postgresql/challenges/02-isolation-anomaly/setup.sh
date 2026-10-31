#!/usr/bin/env bash
# Sets up the "Isolation Anomaly" challenge.
# Prereq: Docker running. Creates an accounts table, seeds it, and plants
# a broken transaction script (fix.sql) in the work directory for the learner
# to repair.
set -euo pipefail

SLUG="02-isolation-anomaly"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

echo "==> Ensuring dojo-pg container is running..."
docker ps -a --format '{{.Names}}' | grep -qx dojo-pg || \
  docker run -d --name dojo-pg \
    -e POSTGRES_PASSWORD=dojo \
    -e POSTGRES_DB=dojo \
    -p 55432:5432 \
    postgres:16-alpine

echo "==> Waiting for PostgreSQL to accept connections..."
until docker exec dojo-pg pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done

echo "==> Seeding accounts table..."
docker exec -i dojo-pg psql -U postgres -d dojo <<'SQL'
DROP TABLE IF EXISTS accounts;
CREATE TABLE accounts (
    id      SERIAL          PRIMARY KEY,
    owner   TEXT            NOT NULL,
    balance NUMERIC(15,2)   NOT NULL DEFAULT 0
);
INSERT INTO accounts (owner, balance) VALUES ('alice', 1000);
SQL

# Plant the broken scenario file so the learner can observe the anomaly first
cat > "$WORK/broken.sql" <<'SQLEOF'
-- broken.sql — demonstrates the lost update
-- Run this in two concurrent psql sessions (open two terminals) and observe
-- the final balance: it should be 2000 (1000 + 500 + 500) but ends up 1500.
--
-- Terminal A: docker exec -i dojo-pg psql -U postgres -d dojo < $HOME/.kube-dojo-work/02-isolation-anomaly/broken.sql
-- Terminal B: docker exec -i dojo-pg psql -U postgres -d dojo < $HOME/.kube-dojo-work/02-isolation-anomaly/broken.sql
-- Then: docker exec dojo-pg psql -U postgres -d dojo -c "SELECT balance FROM accounts WHERE id=1;"
-- Expected 2000, actual 1500 — one update was LOST.

BEGIN;
DO $$
DECLARE
    v_bal NUMERIC;
BEGIN
    -- Read the current balance (no lock — this is the bug)
    SELECT balance INTO v_bal FROM accounts WHERE id = 1;
    PERFORM pg_sleep(0.3);     -- simulate time spent on business logic
    UPDATE accounts SET balance = v_bal + 500 WHERE id = 1;
END;
$$;
COMMIT;
SQLEOF

# Plant the fix stub the learner must edit
cat > "$WORK/fix.sql" <<'SQLEOF'
-- fix.sql — YOUR TASK: prevent the lost update
--
-- The verify script will reset the balance to 0, then run THIS FILE twice
-- concurrently (simulating two simultaneous customer service reps each
-- crediting 500 to account id=1). The final balance MUST be 1000.
--
-- Currently it suffers the same lost-update bug as broken.sql.
-- Add the one SQL keyword that acquires a row-level lock on the SELECT so
-- the second transaction serializes behind the first.
--
-- DO NOT change the amount (500). DO NOT hardcode the target balance.
-- Fix ONLY the SELECT line inside the DO block.

BEGIN;
DO $$
DECLARE
    v_bal NUMERIC;
BEGIN
    -- FIX THIS LINE — add the clause that prevents concurrent reads from
    -- seeing a stale value:
    SELECT balance INTO v_bal FROM accounts WHERE id = 1;
    PERFORM pg_sleep(0.2);
    UPDATE accounts SET balance = v_bal + 500 WHERE id = 1;
END;
$$;
COMMIT;
SQLEOF

echo
echo "Work directory : $WORK"
echo
echo "Files planted:"
echo "  broken.sql  — run this in two terminals simultaneously to see the bug"
echo "  fix.sql     — edit this to prevent the lost update"
echo
echo "After editing fix.sql, verify:"
echo "  bash courses/course-18-postgresql/challenges/$SLUG/verify.sh"
