#!/usr/bin/env bash
# Plants the "Caching and Tag-Based Revalidation" starter project.
# Idempotent — re-running overwrites sources but does not delete node_modules.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/03-caching-and-revalidate"
mkdir -p "$WORK/lib"
mkdir -p "$WORK/test"

# ── package.json ──────────────────────────────────────────────────────────────
cat > "$WORK/package.json" << 'EOF'
{
  "name": "03-caching-and-revalidate",
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

# ── lib/fake-cache.ts (provided — do not modify) ─────────────────────────────
cat > "$WORK/lib/fake-cache.ts" << 'EOF'
// lib/fake-cache.ts
// Test-double for Next.js unstable_cache + revalidateTag.
// API surface is identical to 'next/cache' so swapping the import
// in production code is a one-line change.
// DO NOT MODIFY — the verifier re-writes this file if it is tampered with.

type AnyAsyncFn<T> = (...args: unknown[]) => Promise<T>

interface CacheEntry {
  value: unknown
  tags: string[]
}

const _entries = new Map<string, CacheEntry>()
const _fetchCounts = new Map<string, number>()

/**
 * Wraps `fn` with a tag-aware in-memory cache.
 * Only the first call per key actually invokes `fn`; subsequent calls
 * return the cached value until `revalidateTag` busts it.
 */
export function unstable_cache<T>(
  fn: AnyAsyncFn<T>,
  keyParts: string[],
  options: { tags: string[] }
): AnyAsyncFn<T> {
  const key = keyParts.join(':')
  return async (...args: unknown[]) => {
    const entry = _entries.get(key)
    if (entry) return entry.value as T
    // cache miss — invoke the real function and record the call
    _fetchCounts.set(key, (_fetchCounts.get(key) ?? 0) + 1)
    const value = await fn(...args)
    _entries.set(key, { value, tags: options.tags })
    return value
  }
}

/**
 * Invalidates all cache entries whose tags include `tag`.
 * Matches the Next.js revalidateTag semantics: tag-to-entry, not key-to-entry.
 */
export function revalidateTag(tag: string): void {
  for (const [key, entry] of _entries) {
    if (entry.tags.includes(tag)) {
      _entries.delete(key)
    }
  }
}

/** Returns the number of times the underlying DB function was actually invoked for `keyPart`. */
export function getFetchCount(keyPart: string): number {
  return _fetchCounts.get(keyPart) ?? 0
}

/** Clears all state. Call in test setup to isolate cases. */
export function _resetCache(): void {
  _entries.clear()
  _fetchCounts.clear()
}
EOF

# ── lib/products.ts skeleton ─────────────────────────────────────────────────
cat > "$WORK/lib/products.ts" << 'EOF'
// lib/products.ts
// Implement fetchProducts and invalidateProducts using fake-cache.ts.
//
// In production you would import from 'next/cache'; the fake-cache module
// exposes the same API so this file works in both contexts unchanged.
//
// Requirements:
//   fetchProducts()      — wrap _fetchProductsFromDB with unstable_cache,
//                          keyParts: ['products'], tags: ['products'].
//                          Return Product[].
//   invalidateProducts() — call revalidateTag('products') to bust the cache.

import { unstable_cache, revalidateTag } from './fake-cache.ts'

export type Product = { id: number; name: string; price: number }

// Simulates a slow DB call. The fake-cache harness counts how many times
// this actually executes — your wrapper should call it at most once per
// cache lifetime.
async function _fetchProductsFromDB(): Promise<Product[]> {
  return [
    { id: 1, name: 'Widget', price: 9.99 },
    { id: 2, name: 'Gadget', price: 49.99 },
    { id: 3, name: 'Doohickey', price: 4.99 },
  ]
}

export async function fetchProducts(): Promise<Product[]> {
  // TODO: wrap _fetchProductsFromDB with unstable_cache
  // keyParts: ['products'], tags: ['products']
  throw new Error('not implemented')
}

export function invalidateProducts(): void {
  // TODO: call revalidateTag to bust the 'products' cache tag
  throw new Error('not implemented')
}
EOF

# ── test/sample.test.mts (visible) ───────────────────────────────────────────
cat > "$WORK/test/sample.test.mts" << 'EOF'
// sample.test.mts — visible example showing the call-count pattern.
// The real harness (run by verify.sh) asserts caching and revalidation.
// Make this green first, then think about what the hidden test checks.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { fetchProducts } from '../lib/products.ts'
import { getFetchCount, _resetCache } from '../lib/fake-cache.ts'

test('sample — fetchProducts returns a non-empty array', async () => {
  _resetCache()
  const products = await fetchProducts()
  assert.ok(Array.isArray(products), 'must return an array')
  assert.ok(products.length > 0, 'array must have at least one item')
})

test('sample — calling fetchProducts twice keeps getFetchCount at 1', async () => {
  _resetCache()
  await fetchProducts()
  await fetchProducts()
  const count = getFetchCount('products')
  assert.equal(count, 1, `DB should be called once (cached), but was called ${count} times`)
})
EOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement fetchProducts and invalidateProducts"
echo "                 in lib/products.ts using the provided fake-cache.ts."
echo
echo "Prerequisites  :"
echo "  cd $WORK && npm install"
echo
echo "Run sample test:"
echo "  node --import tsx/esm --test 'test/sample.test.mts'"
echo
echo "Verify + flag  :"
echo "  bash courses/course-32-nextjs-production/challenges/03-caching-and-revalidate/verify.sh"
