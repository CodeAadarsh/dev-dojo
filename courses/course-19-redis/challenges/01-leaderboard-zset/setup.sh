#!/usr/bin/env bash
# Plants the "Leaderboard with a Sorted Set" scenario.
# Idempotent — re-running clears the leaderboard key and rewrites the starter script.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/01-leaderboard-zset"
mkdir -p "$WORK"

# Ensure dojo-redis container is running
docker ps -a --format '{{.Names}}' | grep -qx dojo-redis || \
  docker run -d --name dojo-redis -p 6399:6379 redis:7-alpine

until docker exec dojo-redis redis-cli ping >/dev/null 2>&1; do sleep 1; done
echo "dojo-redis is ready."

# Clear any previous leaderboard state for a clean run
docker exec dojo-redis redis-cli DEL dojo:leaderboard >/dev/null

# Plant the starter script — learner fills in the ZADD arguments
cat > "$WORK/commands.sh" << 'SHEOF'
#!/usr/bin/env bash
# commands.sh — populate dojo:leaderboard
# Usage: bash commands.sh
# This script runs Redis commands via docker exec against the dojo-redis container.
set -euo pipefail

CLI="docker exec dojo-redis redis-cli"

# Clear any leftover state
$CLI DEL dojo:leaderboard

# TODO: Replace this single placeholder with all five players from brief.md.
# ZADD accepts multiple score-member pairs in one call:
#   ZADD dojo:leaderboard <score> <member> [<score> <member> ...]
$CLI ZADD dojo:leaderboard 0 placeholder

echo "--- ZREVRANGE (all members, highest score first) ---"
$CLI ZREVRANGE dojo:leaderboard 0 -1 WITHSCORES

echo "--- ZREVRANK alice (0-indexed from the top) ---"
$CLI ZREVRANK dojo:leaderboard alice
SHEOF
chmod +x "$WORK/commands.sh"

echo
echo "Work directory : $WORK"
echo "Starter script : $WORK/commands.sh"
echo
echo "Next steps:"
echo "  1. Edit $WORK/commands.sh — replace the placeholder ZADD with all five"
echo "     players and scores from brief.md."
echo "  2. Apply the commands:  bash $WORK/commands.sh"
echo "  3. Run the verifier:    bash courses/course-19-redis/challenges/01-leaderboard-zset/verify.sh"
