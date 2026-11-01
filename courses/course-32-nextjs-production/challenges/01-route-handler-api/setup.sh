#!/usr/bin/env bash
# Plants the "Route Handler: Typed API Endpoint" starter project.
# Idempotent — re-running overwrites sources but does not delete node_modules.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/01-route-handler-api"
mkdir -p "$WORK/app/api/todos"
mkdir -p "$WORK/test"

# ── package.json ─────────────────────────────────────────────────────────────
cat > "$WORK/package.json" << 'EOF'
{
  "name": "01-route-handler-api",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "node --import tsx/esm --test 'test/*.test.mts'"
  },
  "devDependencies": {
    "@types/node": "22.10.1",
    "tsx": "4.19.1",
    "typescript": "5.7.2"
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
    "strict": true,
    "skipLibCheck": true
  }
}
EOF

# ── app/api/todos/route.ts skeleton ──────────────────────────────────────────
cat > "$WORK/app/api/todos/route.ts" << 'EOF'
// app/api/todos/route.ts
// Implement GET and POST so the test harness passes.
//
// Rules:
//   • Use the Web API Request / Response only (no next/server import).
//     Node 18+ makes both available as globals.
//   • GET  /api/todos  → 200  { todos: Todo[] }
//   • POST /api/todos  → 201  { todo: Todo }   when body has a non-empty title
//                      → 422  { error: string } when title is missing or empty
//   • Do not remove _reset() — the test harness calls it between cases.

export type Todo = { id: number; title: string; done: boolean }

const _store: Todo[] = []
let _nextId = 1

/** Resets in-memory state between test runs. Do not remove. */
export function _reset(): void {
  _store.length = 0
  _nextId = 1
}

export async function GET(_req: Request): Promise<Response> {
  // TODO: return 200 with JSON body { todos: <the store> }
  return new Response(JSON.stringify({ error: 'not implemented' }), { status: 501 })
}

export async function POST(req: Request): Promise<Response> {
  // TODO: parse JSON body, validate title, push to _store, return 201 or 422
  return new Response(JSON.stringify({ error: 'not implemented' }), { status: 501 })
}
EOF

# ── test/sample.test.mts (visible — shows the import pattern) ────────────────
cat > "$WORK/test/sample.test.mts" << 'EOF'
// sample.test.mts — a VISIBLE example showing how to import and call the handler.
// The real harness (run by verify.sh) tests more cases. Make this green first.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { GET, _reset } from '../app/api/todos/route.ts'

test('sample — GET returns a 200 Response', async () => {
  _reset()
  const req = new Request('http://localhost/api/todos')
  const res = await GET(req)
  assert.equal(res.status, 200, `expected 200, got ${res.status}`)
  const body = await res.json()
  assert.ok('todos' in body, 'response body must have a "todos" key')
  assert.ok(Array.isArray(body.todos), '"todos" must be an array')
})
EOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement GET and POST in app/api/todos/route.ts"
echo "                 so node --test passes all status-code assertions."
echo
echo "Prerequisites  :"
echo "  cd $WORK && npm install"
echo
echo "Run sample test:"
echo "  node --import tsx/esm --test 'test/sample.test.mts'"
echo
echo "Verify + flag  :"
echo "  bash courses/course-32-nextjs-production/challenges/01-route-handler-api/verify.sh"
