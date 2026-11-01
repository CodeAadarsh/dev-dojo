#!/usr/bin/env bash
# Verifier for "Middleware Auth Guard".
# Imports the learner's middleware module via node --test and runs the full
# hidden harness. Prints the flag only when every assertion passes.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/04-middleware-auth"
FLAG='KUBE{middleware_guards_the_gate}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/src/middleware.ts" ] || fail "src/middleware.ts not found in $WORK"

cd "$WORK"

# Install deps quietly if needed
npm install --prefer-offline --silent 2>/dev/null || npm install --silent 2>/dev/null || fail "npm install failed"

# Write the hidden full test harness into a temp file
TMPTEST="$(mktemp /tmp/verify-middleware-XXXXXX.mts)"
trap 'rm -f "$TMPTEST"' EXIT

cat > "$TMPTEST" << 'TESTEOF'
import { test } from "node:test";
import assert from "node:assert/strict";

// Dynamic import so TypeScript path resolves from WORK
const { middleware } = await import(process.env.MIDDLEWARE_PATH);

function req(path, sessionCookie) {
  return {
    url: `http://localhost:3000${path}`,
    cookies: {
      get(name) {
        if (name === "session" && sessionCookie !== undefined) return { value: sessionCookie };
        return undefined;
      },
    },
  };
}

// Protected paths — no cookie → redirect
test("redirect /dashboard/overview no cookie", async () => {
  const r = middleware(req("/dashboard/overview"));
  assert.ok("redirect" in r);
  assert.equal(r.redirect, "/login");
});

test("redirect /settings no cookie", async () => {
  const r = middleware(req("/settings"));
  assert.ok("redirect" in r);
  assert.equal(r.redirect, "/login");
});

test("redirect /account/profile no cookie", async () => {
  const r = middleware(req("/account/profile"));
  assert.ok("redirect" in r);
  assert.equal(r.redirect, "/login");
});

test("redirect /admin no cookie", async () => {
  const r = middleware(req("/admin"));
  assert.ok("redirect" in r);
  assert.equal(r.redirect, "/login");
});

// Protected paths — with cookie → pass
test("pass /dashboard/overview with session cookie", async () => {
  const r = middleware(req("/dashboard/overview", "tok123"));
  assert.ok("next" in r);
});

test("pass /settings with session cookie", async () => {
  const r = middleware(req("/settings", "tok456"));
  assert.ok("next" in r);
});

// Always-public paths
test("pass /login", async () => {
  const r = middleware(req("/login"));
  assert.ok("next" in r);
});

test("pass /signup", async () => {
  const r = middleware(req("/signup"));
  assert.ok("next" in r);
});

test("pass /", async () => {
  const r = middleware(req("/"));
  assert.ok("next" in r);
});

test("pass /favicon.ico", async () => {
  const r = middleware(req("/favicon.ico"));
  assert.ok("next" in r);
});

// _next static assets — never redirect regardless of cookie
test("pass /_next/static/chunk.js", async () => {
  const r = middleware(req("/_next/static/chunk.js"));
  assert.ok("next" in r);
});

test("pass /_next/image?url=...", async () => {
  const r = middleware(req("/_next/image?url=foo.png&w=64&q=75"));
  assert.ok("next" in r);
});

// API routes — never guarded
test("pass /api/public no cookie", async () => {
  const r = middleware(req("/api/public"));
  assert.ok("next" in r);
});

test("pass /api/auth/callback no cookie", async () => {
  const r = middleware(req("/api/auth/callback"));
  assert.ok("next" in r);
});
TESTEOF

MIDDLEWARE_PATH="$WORK/src/middleware.ts" \
  node --experimental-strip-types --test "$TMPTEST" 2>&1

STATUS=$?

if [ $STATUS -eq 0 ]; then
  echo
  echo "All tests passed. Submit this flag in the platform:"
  echo
  echo "    $FLAG"
else
  fail "test suite has failures — fix your middleware and retry"
fi
