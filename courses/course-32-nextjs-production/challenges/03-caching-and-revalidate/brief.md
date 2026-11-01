# Caching and Tag-Based Revalidation

A performance review finds the product listing page making a database round-trip on every request. The fix is `unstable_cache` — Next.js's cache primitive that memoises async functions, persists across requests, and ties invalidation to string tags rather than individual keys.

The catch: the team's on-call engineer needs to call `revalidateTag('products')` from an admin action to flush stale data after a product update. If `invalidateProducts()` is wired up incorrectly, the cache never busts and editors see stale prices for up to 24 hours.

Your job: implement `fetchProducts` and `invalidateProducts` in `lib/products.ts` until the `node --test` harness goes green. The harness uses a provided `fake-cache.ts` that counts the number of times the underlying DB function is actually invoked — proving caching and revalidation without running a server.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/03-caching-and-revalidate/
├── package.json
├── tsconfig.json
├── lib/
│   ├── fake-cache.ts   # test-double for unstable_cache + revalidateTag — do not modify
│   └── products.ts     # stub: fetchProducts throws, invalidateProducts throws
└── test/
    └── sample.test.mts # visible test showing the import + call-count pattern
```

**`fake-cache.ts` API surface** — identical to Next.js so swapping the import in production is a one-line change:

| Export | Matches Next.js |
|--------|----------------|
| `unstable_cache(fn, keyParts, { tags })` | `next/cache` `unstable_cache` |
| `revalidateTag(tag)` | `next/cache` `revalidateTag` |
| `getFetchCount(keyPart)` | test-only — counts actual DB invocations |
| `_resetCache()` | test-only — clears all state between test cases |

## Prerequisites

```bash
cd ~/.kube-dojo-work/03-caching-and-revalidate
npm install
```

## Mission

Implement two exports in `lib/products.ts`:

1. **`fetchProducts()`** — wrap the provided `_fetchProductsFromDB` with `unstable_cache`, using key `['products']` and tag `'products'`. Return `Product[]`. The harness asserts that calling `fetchProducts()` three times in a row causes `_fetchProductsFromDB` to run exactly once.

2. **`invalidateProducts()`** — call `revalidateTag('products')` to bust all cache entries tagged `'products'`. After this call, the next `fetchProducts()` must re-invoke the DB function.

The exact conditions `verify.sh` checks:

| Scenario | Expected `getFetchCount('products')` |
|----------|--------------------------------------|
| Three consecutive `fetchProducts()` calls | `1` |
| One more `fetchProducts()` after `invalidateProducts()` | `2` |

## Why this model matters

`unstable_cache` is the non-`fetch` equivalent of `{ next: { tags } }` for route-based caching. The tag model decouples *what* is cached (a key) from *how* it is invalidated (a tag): many keys can share a tag, and `revalidateTag('products')` flushes all of them atomically. This is how Next.js lets a CMS webhook call one function and invalidate every page that touches product data — without enumerating every URL. Understanding that `revalidateTag` targets *tags on entries* not *the keyParts string* is the common source of bugs.

## Run your implementation

```bash
cd ~/.kube-dojo-work/03-caching-and-revalidate
node --import tsx/esm --test 'test/sample.test.mts'
```

## Verify

```bash
bash courses/course-32-nextjs-production/challenges/03-caching-and-revalidate/verify.sh
```

All checks green → flag printed.
