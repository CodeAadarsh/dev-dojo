#!/usr/bin/env bash
# Verifier for "Caching and Tag-Based Revalidation".
# Restores fake-cache.ts, writes a hidden test, runs node --test, prints flag.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/03-caching-and-revalidate"
FLAG='KUBE{cache_tag_revalidation_works}'
HIDDEN="$WORK/test/_hidden.test.mts"

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]                   || fail "work directory missing — run setup.sh first"
[ -f "$WORK/lib/products.ts" ]   || fail "lib/products.ts not found — run setup.sh first"
[ -d "$WORK/node_modules" ]      || fail "node_modules missing — cd $WORK && npm install"

# Restore fake-cache.ts to the known-good version so it cannot be gamed.
cat > "$WORK/lib/fake-cache.ts" << 'TSEOF'
type AnyAsyncFn<T> = (...args: unknown[]) => Promise<T>
interface CacheEntry { value: unknown; tags: string[] }
const _entries = new Map<string, CacheEntry>()
const _fetchCounts = new Map<string, number>()
export function unstable_cache<T>(fn: AnyAsyncFn<T>, keyParts: string[], options: { tags: string[] }): AnyAsyncFn<T> {
  const key = keyParts.join(':')
  return async (...args: unknown[]) => {
    const entry = _entries.get(key)
    if (entry) return entry.value as T
    _fetchCounts.set(key, (_fetchCounts.get(key) ?? 0) + 1)
    const value = await fn(...args)
    _entries.set(key, { value, tags: options.tags })
    return value
  }
}
export function revalidateTag(tag: string): void {
  for (const [key, entry] of _entries) { if (entry.tags.includes(tag)) _entries.delete(key) }
}
export function getFetchCount(keyPart: string): number { return _fetchCounts.get(keyPart) ?? 0 }
export function _resetCache(): void { _entries.clear(); _fetchCounts.clear() }
TSEOF

# Write the hidden test
cat > "$HIDDEN" << 'TSEOF'
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { fetchProducts, invalidateProducts } from '../lib/products.ts'
import { getFetchCount, _resetCache } from '../lib/fake-cache.ts'

test('three consecutive fetchProducts calls result in exactly one DB call', async () => {
  _resetCache()
  await fetchProducts()
  await fetchProducts()
  await fetchProducts()
  const count = getFetchCount('products')
  assert.equal(count, 1, `DB should be called once (cached on 2nd+3rd), but was called ${count} times`)
})

test('fetchProducts returns Product[] with correct shape', async () => {
  _resetCache()
  const products = await fetchProducts()
  assert.ok(Array.isArray(products), 'fetchProducts must return an array')
  assert.ok(products.length >= 1, 'must return at least one product')
  const p = products[0]
  assert.ok(typeof p.id === 'number', 'product.id must be a number')
  assert.ok(typeof p.name === 'string' && p.name.length > 0, 'product.name must be a non-empty string')
  assert.ok(typeof p.price === 'number', 'product.price must be a number')
})

test('invalidateProducts busts the cache so the next fetch hits the DB again', async () => {
  _resetCache()
  await fetchProducts()           // DB call #1
  invalidateProducts()            // bust the cache
  await fetchProducts()           // DB call #2 — must re-invoke because cache was cleared
  const count = getFetchCount('products')
  assert.equal(count, 2, `after revalidation the DB should be called again (total 2), but count is ${count}`)
})

test('after revalidation, the re-fetched data is still correct', async () => {
  _resetCache()
  await fetchProducts()
  invalidateProducts()
  const products = await fetchProducts()
  assert.ok(Array.isArray(products) && products.length >= 1, 're-fetched products must still be valid')
})

test('invalidateProducts is synchronous (does not return a rejected promise)', async () => {
  _resetCache()
  await fetchProducts()
  let threw = false
  try {
    const result = invalidateProducts()
    if (result instanceof Promise) await result
  } catch {
    threw = true
  }
  assert.equal(threw, false, 'invalidateProducts must not throw or reject')
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
