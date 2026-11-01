#!/usr/bin/env bash
# Verifier for "Server Action: Validated Form Submission".
# Writes a hidden test, runs it with node --test, prints flag only on full pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/02-server-action"
FLAG='KUBE{server_actions_validate_and_type}'
HIDDEN="$WORK/test/_hidden.test.mts"

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]                     || fail "work directory missing — run setup.sh first"
[ -f "$WORK/actions/contact.ts" ]  || fail "actions/contact.ts not found — run setup.sh first"
[ -d "$WORK/node_modules" ]        || fail "node_modules missing — cd $WORK && npm install"

cat > "$HIDDEN" << 'TSEOF'
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { submitContact } from '../actions/contact.ts'

test('valid input returns ok=true with a full Contact object', async () => {
  const result = await submitContact({ name: 'Bob', email: 'bob@corp.io' })
  assert.equal(result.ok, true, `expected ok=true, got ok=${result.ok}`)
  if (!result.ok) throw new Error('unreachable')
  assert.ok(typeof result.data.id === 'string' && result.data.id.length > 0, 'id must be a non-empty string')
  assert.equal(result.data.name, 'Bob')
  assert.equal(result.data.email, 'bob@corp.io')
  assert.ok(typeof result.data.createdAt === 'string' && result.data.createdAt.includes('T'), 'createdAt must be an ISO 8601 string')
})

test('empty name returns ok=false with a non-empty error', async () => {
  const result = await submitContact({ name: '', email: 'x@y.com' })
  assert.equal(result.ok, false, `expected ok=false for empty name, got ok=${result.ok}`)
  if (result.ok) throw new Error('unreachable')
  assert.ok(typeof result.error === 'string' && result.error.length > 0, 'error must be a non-empty string')
})

test('whitespace-only name returns ok=false', async () => {
  const result = await submitContact({ name: '   ', email: 'x@y.com' })
  assert.equal(result.ok, false, 'whitespace-only name should fail validation')
})

test('email without @ returns ok=false', async () => {
  const result = await submitContact({ name: 'Carol', email: 'notanemail' })
  assert.equal(result.ok, false, `expected ok=false for email without @, got ok=${result.ok}`)
})

test('empty email returns ok=false', async () => {
  const result = await submitContact({ name: 'Dave', email: '' })
  assert.equal(result.ok, false, `expected ok=false for empty email, got ok=${result.ok}`)
})

test('action does not throw on invalid input — returns result instead', async () => {
  let threw = false
  try {
    await submitContact({ name: '', email: '' })
  } catch {
    threw = true
  }
  assert.equal(threw, false, 'submitContact must never throw — return { ok: false } instead')
})

test('each valid submission gets a unique id', async () => {
  const r1 = await submitContact({ name: 'Eve', email: 'e@e.com' })
  const r2 = await submitContact({ name: 'Frank', email: 'f@f.com' })
  if (!r1.ok || !r2.ok) throw new Error('both should succeed')
  assert.notEqual(r1.data.id, r2.data.id, 'each Contact must have a unique id')
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
