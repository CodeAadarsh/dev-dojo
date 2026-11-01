#!/usr/bin/env bash
# Verifier for "Route Handler: Typed API Endpoint".
# Writes a hidden test, runs it with node --test, prints flag only on full pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/01-route-handler-api"
FLAG='KUBE{route_handler_validates_and_responds}'
HIDDEN="$WORK/test/_hidden.test.mts"

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]                          || fail "work directory missing — run setup.sh first"
[ -f "$WORK/app/api/todos/route.ts" ]   || fail "route.ts not found — run setup.sh first"
[ -d "$WORK/node_modules" ]             || fail "node_modules missing — cd $WORK && npm install"

# Write the hidden test file
cat > "$HIDDEN" << 'TSEOF'
import { test, before } from 'node:test'
import assert from 'node:assert/strict'
import { GET, POST, _reset } from '../app/api/todos/route.ts'

before(() => _reset())

test('GET returns 200 with empty todos array', async () => {
  _reset()
  const res = await GET(new Request('http://localhost/api/todos'))
  assert.equal(res.status, 200, `GET must return 200, got ${res.status}`)
  const body = await res.json()
  assert.ok(Array.isArray(body.todos), 'body.todos must be an array')
  assert.equal(body.todos.length, 0, 'store must start empty (call _reset before each test)')
})

test('POST with valid title returns 201 and the new todo', async () => {
  _reset()
  const res = await POST(new Request('http://localhost/api/todos', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ title: 'Buy milk' }),
  }))
  assert.equal(res.status, 201, `POST with valid body must return 201, got ${res.status}`)
  const body = await res.json()
  assert.ok(body.todo, 'response body must have a "todo" key')
  assert.equal(body.todo.title, 'Buy milk')
  assert.equal(body.todo.done, false)
  assert.ok(typeof body.todo.id === 'number', 'todo.id must be a number')
})

test('GET returns the newly created todo', async () => {
  _reset()
  await POST(new Request('http://localhost/api/todos', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ title: 'Read docs' }),
  }))
  const res = await GET(new Request('http://localhost/api/todos'))
  assert.equal(res.status, 200)
  const body = await res.json()
  assert.equal(body.todos.length, 1)
  assert.equal(body.todos[0].title, 'Read docs')
})

test('POST missing title returns 422', async () => {
  const res = await POST(new Request('http://localhost/api/todos', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ count: 5 }),
  }))
  assert.equal(res.status, 422, `POST with missing title must return 422, got ${res.status}`)
})

test('POST with empty title returns 422', async () => {
  const res = await POST(new Request('http://localhost/api/todos', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ title: '   ' }),
  }))
  assert.equal(res.status, 422, `POST with blank title must return 422, got ${res.status}`)
})

test('POST assigns incrementing ids', async () => {
  _reset()
  const r1 = await POST(new Request('http://localhost/api/todos', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ title: 'First' }),
  }))
  const r2 = await POST(new Request('http://localhost/api/todos', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ title: 'Second' }),
  }))
  const t1 = (await r1.json()).todo
  const t2 = (await r2.json()).todo
  assert.notEqual(t1.id, t2.id, 'each todo must have a unique id')
})
TSEOF

cd "$WORK"
if node --import tsx/esm --test "$HIDDEN" 2>&1; then
  rm -f "$HIDDEN"
  echo
  echo "All checks passed. Submit this flag in the platform:"
  echo
  echo "    $FLAG"
else
  rm -f "$HIDDEN"
  fail "test suite has failures — fix your implementation and retry"
fi
