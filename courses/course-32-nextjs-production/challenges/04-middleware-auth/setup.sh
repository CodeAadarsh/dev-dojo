#!/usr/bin/env bash
# Plants the middleware-auth starter project.
# Idempotent — re-running overwrites source files but preserves node_modules.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/04-middleware-auth"
mkdir -p "$WORK/src" "$WORK/tests"

# ── package.json ─────────────────────────────────────────────────────────────
cat > "$WORK/package.json" << 'EOF'
{
  "name": "middleware-auth",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "test": "node --test tests/middleware.test.ts"
  },
  "dependencies": {
    "next": "14.2.29"
  },
  "devDependencies": {
    "@types/node": "20.14.2",
    "typescript": "5.5.2"
  }
}
EOF

# ── tsconfig.json ─────────────────────────────────────────────────────────────
cat > "$WORK/tsconfig.json" << 'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "lib": ["ES2022"],
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "outDir": "dist"
  },
  "include": ["src", "tests"]
}
EOF

# ── src/middleware.ts stub ─────────────────────────────────────────────────────
cat > "$WORK/src/middleware.ts" << 'EOF'
// middleware.ts — implement the auth guard here
//
// Export a function named `middleware` that accepts a request object
// with a { url: string, cookies: { get(name: string): { value: string } | undefined } }
// shape and returns either:
//   { redirect: string }        when the request should be redirected to /login
//   { next: true }              when the request should pass through
//
// The verifier imports this module directly (no Next.js runtime needed).

export function middleware(req: {
  url: string;
  cookies: { get(name: string): { value: string } | undefined };
}): { redirect: string } | { next: true } {
  // TODO: implement
  throw new Error("not implemented");
}
EOF

# ── tests/middleware.test.ts (visible sample) ─────────────────────────────────
cat > "$WORK/tests/middleware.test.ts" << 'EOF'
// Sample tests — a subset of the hidden verifier harness.
// Run: node --test tests/middleware.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { middleware } from "../src/middleware.ts";

function req(
  path: string,
  sessionCookie?: string
): { url: string; cookies: { get(n: string): { value: string } | undefined } } {
  return {
    url: `http://localhost:3000${path}`,
    cookies: {
      get(name: string) {
        if (name === "session" && sessionCookie !== undefined) {
          return { value: sessionCookie };
        }
        return undefined;
      },
    },
  };
}

test("redirects /dashboard/overview without session cookie", () => {
  const result = middleware(req("/dashboard/overview"));
  assert.ok("redirect" in result, "expected a redirect response");
  assert.equal((result as { redirect: string }).redirect, "/login");
});

test("passes through /dashboard/overview with session cookie", () => {
  const result = middleware(req("/dashboard/overview", "abc123"));
  assert.ok("next" in result, "expected pass-through");
});

test("passes through /login (public path)", () => {
  const result = middleware(req("/login"));
  assert.ok("next" in result, "expected pass-through for /login");
});

test("passes through /_next/static/chunk.js", () => {
  const result = middleware(req("/_next/static/chunk.js"));
  assert.ok("next" in result, "expected pass-through for static asset");
});
EOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement the auth guard in src/middleware.ts"
echo "                 so that all node --test cases pass."
echo
echo "Prerequisites  :"
echo "  cd $WORK && npm install"
echo
echo "Run sample tests : node --test tests/middleware.test.ts"
echo "Verify + flag    : bash courses/course-32-nextjs-production/challenges/04-middleware-auth/verify.sh"
