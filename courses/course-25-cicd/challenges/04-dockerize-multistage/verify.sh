#!/usr/bin/env bash
# Verifier for "Dockerize Multi-Stage".
# Builds the learner's Dockerfile, runs the image, checks non-root user and
# /healthz response. Prints the flag only when all checks pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/04-dockerize-multistage"
IMAGE="dojo-multistage:dojo-verify"
CONTAINER="dojo-ms-verify"
PORT=18480
FLAG='KUBE{multistage_build_slim_nonroot}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/Dockerfile" ] || fail "Dockerfile not found in $WORK — write the Dockerfile first"
[ -f "$WORK/build.sh" ]   || fail "build.sh not found in $WORK — write the build script first"

cd "$WORK"

# ── 1. Multi-stage check: must have ≥ 2 FROM instructions ───────────────────
FROM_COUNT=$(grep -E '^FROM ' Dockerfile 2>/dev/null | wc -l | tr -d ' ')
[ "${FROM_COUNT:-0}" -ge 2 ] \
  || fail "Dockerfile has $FROM_COUNT FROM instruction(s) — must have ≥ 2 (multi-stage: one builder, one runtime)"

# ── 2. Build the image ───────────────────────────────────────────────────────
echo "Building image (this may pull golang:1.22-alpine on first run) ..."
docker build -t "$IMAGE" . \
  || fail "docker build failed — check your Dockerfile syntax and build arguments"

# ── 3. Non-root USER check ───────────────────────────────────────────────────
USER_VAL=$(docker inspect "$IMAGE" --format '{{.Config.User}}' 2>/dev/null)
[ -n "$USER_VAL" ] \
  || fail "image has no USER set — add 'RUN adduser ...' and 'USER <name>' to the runtime stage"
[ "$USER_VAL" = "root" ] \
  && fail "image USER is 'root' — create a non-root user and switch to it with USER"
[ "$USER_VAL" = "0" ] \
  && fail "image USER is '0' (root UID) — create a non-root user and switch to it with USER"

# ── 4. Container responds on /healthz ────────────────────────────────────────
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d -p "${PORT}:8080" --name "$CONTAINER" "$IMAGE" >/dev/null 2>&1 \
  || fail "container failed to start — verify ENTRYPOINT/CMD and that the app binds to port 8080"
sleep 2
RESP=$(curl -s --max-time 5 "http://localhost:${PORT}/healthz" 2>/dev/null || echo "")
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
echo "$RESP" | grep -q "ok" \
  || fail "/healthz did not return 'ok' (response: '${RESP}') — confirm the app listens on 8080 and /healthz returns the string 'ok'"

echo "✓ multi-stage build               : $FROM_COUNT FROM instructions found"
echo "✓ docker build succeeded"
echo "✓ runtime is non-root             : USER=$USER_VAL"
echo "✓ /healthz responded              : ok"
echo
echo "All checks passed. Submit this flag:"
echo
echo "    $FLAG"
