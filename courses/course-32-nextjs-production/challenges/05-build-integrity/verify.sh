#!/usr/bin/env bash
# Verifier for "Build Integrity".
# Runs `npx next build` in the work directory. Exits 0 and prints the flag
# only when the build succeeds.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/05-build-integrity"
FLAG='KUBE{fix_the_build_ship_the_app}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/package.json" ] || fail "package.json not found — run setup.sh first"
[ -f "$WORK/next.config.js" ] || fail "next.config.js not found — run setup.sh first"

cd "$WORK"

echo "Running: npm install (quiet)..."
npm install --prefer-offline --silent 2>/dev/null || npm install --silent 2>/dev/null || fail "npm install failed"

echo "Running: npx next build..."
if npx next build 2>&1; then
  echo
  echo "Build succeeded. Submit this flag in the platform:"
  echo
  echo "    $FLAG"
else
  fail "next build failed — check the error output above and fix the bug"
fi
