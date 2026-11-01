#!/usr/bin/env bash
# Plants the "Type-Safe Endpoint" TypeScript + Fastify + Zod starter project.
# Idempotent — re-running overwrites source files but preserves node_modules.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/01-type-safe-endpoint"
mkdir -p "$WORK/src" "$WORK/test"

# ── package.json ──────────────────────────────────────────────────────────────
cat > "$WORK/package.json" << 'EOF'
{
  "name": "type-safe-endpoint",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "test": "tsx --test test/sample.test.ts"
  },
  "dependencies": {
    "fastify": "4.28.1",
    "zod": "3.23.8"
  },
  "devDependencies": {
    "@types/node": "20.14.9",
    "tsx": "4.19.1",
    "typescript": "5.5.4"
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
    "esModuleInterop": true,
    "skipLibCheck": true
  },
  "include": ["src", "test"]
}
EOF

# ── src/app.ts — skeleton ─────────────────────────────────────────────────────
cat > "$WORK/src/app.ts" << 'EOF'
import Fastify from 'fastify'
import { z } from 'zod'

export const app = Fastify({ logger: false })

// ── Schema & Types ────────────────────────────────────────────────────────────

const ProductSchema = z.object({
  name: z.string().min(1),
  price: z.number().positive(),
  category: z.string().optional(),
})

// TypeScript type inferred directly from the Zod schema — one source of truth.
export type Product = z.infer<typeof ProductSchema> & { id: number }

// ── In-memory store ───────────────────────────────────────────────────────────
const store = new Map<number, Product>()
let nextId = 1

// ── Routes ────────────────────────────────────────────────────────────────────

// POST /products
// Validate request.body with ProductSchema.safeParse().
//   Invalid body   → 400 + { error: string, issues: ZodIssue[] }
//   Valid body     → store product, 201 + the new Product (with id)
app.post('/products', async (request, reply) => {
  return reply.status(501).send({ error: 'not implemented' })
})

// GET /products/:id
// Parse id as integer. If found → 200 + Product. If not → 404.
app.get<{ Params: { id: string } }>('/products/:id', async (request, reply) => {
  return reply.status(501).send({ error: 'not implemented' })
})

// PUT /products/:id
// 404 if id not in store.
// Validate body with ProductSchema.safeParse() → 400 on failure.
// On success → replace product in store, 200 + updated Product.
app.put<{ Params: { id: string } }>('/products/:id', async (request, reply) => {
  return reply.status(501).send({ error: 'not implemented' })
})
EOF

# ── test/sample.test.ts — visible sample test ─────────────────────────────────
cat > "$WORK/test/sample.test.ts" << 'EOF'
// sample.test.ts — run this to confirm your POST handler works.
// Run: npm test   (or: npx tsx --test test/sample.test.ts)
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { app } from '../src/app.ts'

// Fastify's .inject() sends a request in-process — no network, no port needed.
test('sample: POST /products with valid body → 201', async () => {
  const res = await app.inject({
    method: 'POST',
    url: '/products',
    payload: { name: 'Widget', price: 9.99 },
  })
  // Stub returns 501. Implement the handler to make this pass.
  assert.equal(res.statusCode, 201, `expected 201, got ${res.statusCode}: ${res.body}`)
  const body = JSON.parse(res.body) as { id: number; name: string; price: number }
  assert.ok(typeof body.id === 'number', 'response must include a numeric id')
  assert.equal(body.name, 'Widget')
  assert.equal(body.price, 9.99)
})
EOF

# ── print next steps ──────────────────────────────────────────────────────────
echo
echo "Work directory : $WORK"
echo
echo "Task           : implement the three handler bodies in src/app.ts"
echo "                 so the full node:test harness passes."
echo
echo "Prerequisites  :"
echo "  cd $WORK && npm install"
echo
echo "Run sample test: cd $WORK && npm test"
echo "Verify + flag  : bash courses/course-33-node-backend-scale/challenges/01-type-safe-endpoint/verify.sh"
