# Solution — Caching and Tag-Based Revalidation

The complete `lib/products.ts`. Key points below the code.

```typescript
import { unstable_cache, revalidateTag } from './fake-cache.ts'

export type Product = { id: number; name: string; price: number }

async function _fetchProductsFromDB(): Promise<Product[]> {
  return [
    { id: 1, name: 'Widget', price: 9.99 },
    { id: 2, name: 'Gadget', price: 49.99 },
    { id: 3, name: 'Doohickey', price: 4.99 },
  ]
}

const _cachedFetchProducts = unstable_cache(
  _fetchProductsFromDB,
  ['products'],
  { tags: ['products'] }
)

export async function fetchProducts(): Promise<Product[]> {
  return _cachedFetchProducts()
}

export function invalidateProducts(): void {
  revalidateTag('products')
}
```

## Why each piece matters

**`unstable_cache` is called once at module load, not inside `fetchProducts`.**
This is the critical correctness point. If you write:

```typescript
// WRONG — creates a new cached wrapper on every call: cache is never hit
export async function fetchProducts() {
  return unstable_cache(_fetchProductsFromDB, ['products'], { tags: ['products'] })()
}
```

...each invocation creates a fresh wrapper instance with an empty local cache. The wrapper must be created once and reused. The pattern is: `const _cached = unstable_cache(fn, key, opts)` at module scope, then `export function fetchProducts() { return _cached() }`.

**`keyParts` vs `tags` — two different things.**
`keyParts` (`['products']`) is the *cache key* — it uniquely identifies what is cached. `tags` (`['products']`) is the *invalidation group* — it controls what `revalidateTag` can flush. They look the same here because the resource has one key and one tag, but a more complex scenario might be `keyParts: ['products', 'category', 'electronics']` with `tags: ['products', 'electronics']` — so both `revalidateTag('products')` and `revalidateTag('electronics')` flush that entry.

**`revalidateTag` targets entries by tag, not by key.**
This is the model that makes Next.js caching powerful at scale. A CMS webhook calls `revalidateTag('products')` once and every cached page, layout, route handler, and data function that tagged its result `'products'` is invalidated — without the webhook knowing what keys exist. The keys are an implementation detail; the tag is the public contract.

**`invalidateProducts` is synchronous.**
`revalidateTag` (both the fake and the real Next.js one) is synchronous — it mutates the cache store immediately. There is no `await` here. The asynchrony is in `fetchProducts` because database calls are async, not because cache operations are.

## Swap to real Next.js

In production, change one line:

```typescript
// was:
import { unstable_cache, revalidateTag } from './fake-cache.ts'
// becomes:
import { unstable_cache, revalidateTag } from 'next/cache'
```

Everything else stays identical. The `getFetchCount` and `_resetCache` imports exist only in the test environment and are not used in `products.ts`, so nothing breaks.

## Apply and verify

```bash
cd ~/.kube-dojo-work/03-caching-and-revalidate
# replace lib/products.ts with the solution above, then:
node --import tsx/esm --test 'test/sample.test.mts'
bash courses/course-32-nextjs-production/challenges/03-caching-and-revalidate/verify.sh
```
