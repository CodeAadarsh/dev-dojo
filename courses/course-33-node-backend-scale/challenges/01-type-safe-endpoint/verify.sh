#!/usr/bin/env bash
# Verifier for "Type-Safe Endpoint".
# Writes a hidden test file, runs it with tsx, prints the flag only on all-pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/01-type-safe-endpoint"
FLAG='KUBE{zod_guards_the_gate}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]            || fail "work directory missing — run setup.sh first"
[ -f "$WORK/src/app.ts" ] || fail "src/app.ts not found — run setup.sh first"

cd "$WORK"
npm install --silent 2>/dev/null || npm install 2>&1 | tail -5

# ── write hidden test file ────────────────────────────────────────────────────
HIDDEN="$WORK/test/_verify_hidden.test.ts"
cat > "$HIDDEN" << 'TESTEOF'
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { app } from '../src/app.ts'

test('POST /products — valid body returns 201 with typed product', async () => {
  const res = await app.inject({
    method: 'POST',
    url: '/products',
    payload: { name: 'Wrench', price: 12.99 },
  })
  assert.equal(res.statusCode, 201, `expected 201, got ${res.statusCode}: ${res.body}`)
  const body = JSON.parse(res.body)
  assert.ok(typeof body.id === 'number', 'id must be a number')
  assert.equal(body.name, 'Wrench')
  assert.equal(body.price, 12.99)
})

test('POST /products — missing price returns 400', async () => {
  const res = await app.inject({
    method: 'POST',
    url: '/products',
    payload: { name: 'NoPriceWidget' },
  })
  assert.equal(res.statusCode, 400, `missing price: expected 400, got ${res.statusCode}`)
})

test('POST /products — negative price returns 400', async () => {
  const res = await app.inject({
    method: 'POST',
    url: '/products',
    payload: { name: 'NegativePrice', price: -5 },
  })
  assert.equal(res.statusCode, 400, `negative price: expected 400, got ${res.statusCode}`)
})

test('POST /products — empty name returns 400', async () => {
  const res = await app.inject({
    method: 'POST',
    url: '/products',
    payload: { name: '', price: 10 },
  })
  assert.equal(res.statusCode, 400, `empty name: expected 400, got ${res.statusCode}`)
})

test('GET /products/:id — existing product returns 200 with correct body', async () => {
  const create = await app.inject({
    method: 'POST',
    url: '/products',
    payload: { name: 'Bolt', price: 0.99, category: 'hardware' },
  })
  assert.equal(create.statusCode, 201, `setup POST failed: ${create.body}`)
  const { id } = JSON.parse(create.body)

  const res = await app.inject({ method: 'GET', url: `/products/${id}` })
  assert.equal(res.statusCode, 200, `GET existing: expected 200, got ${res.statusCode}`)
  const body = JSON.parse(res.body)
  assert.equal(body.id, id)
  assert.equal(body.category, 'hardware')
})

test('GET /products/:id — unknown id returns 404', async () => {
  const res = await app.inject({ method: 'GET', url: '/products/999999' })
  assert.equal(res.statusCode, 404, `GET unknown: expected 404, got ${res.statusCode}`)
})

test('PUT /products/:id — valid update returns 200 with new data', async () => {
  const create = await app.inject({
    method: 'POST',
    url: '/products',
    payload: { name: 'Old Name', price: 5.0 },
  })
  assert.equal(create.statusCode, 201, `setup POST failed: ${create.body}`)
  const { id } = JSON.parse(create.body)

  const res = await app.inject({
    method: 'PUT',
    url: `/products/${id}`,
    payload: { name: 'New Name', price: 7.5 },
  })
  assert.equal(res.statusCode, 200, `PUT: expected 200, got ${res.statusCode}`)
  const body = JSON.parse(res.body)
  assert.equal(body.name, 'New Name')
  assert.equal(body.price, 7.5)
  assert.equal(body.id, id, 'id must not change on update')
})

test('PUT /products/:id — unknown id returns 404', async () => {
  const res = await app.inject({
    method: 'PUT',
    url: '/products/999999',
    payload: { name: 'X', price: 1.0 },
  })
  assert.equal(res.statusCode, 404, `PUT unknown: expected 404, got ${res.statusCode}`)
})
TESTEOF

if "$WORK/node_modules/.bin/tsx" --test "$HIDDEN" 2>&1; then
  rm -f "$HIDDEN"
  echo
  echo "All checks passed. Submit this flag in the platform:"
  echo
  echo "    $FLAG"
else
  rm -f "$HIDDEN"
  fail "one or more checks failed — fix your implementation and retry"
fi
