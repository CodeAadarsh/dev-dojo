# Typed Queries and N+1 Prevention

A performance review flags a `/authors` endpoint with p99 = 1.2 s in production. Query log shows 51 SQL statements per request — one SELECT for the author list, then one SELECT per author for their posts. With 50 authors it's 51 queries; with 500 it would be 501. The ticket: *"fix the N+1, add Zod-style typing via Drizzle's inferred types, and wrap the author+post creation in a transaction so we don't end up with orphaned authors if the post insert fails."*

## Context

`setup.sh` plants a TypeScript + Drizzle + better-sqlite3 project:

```
~/.kube-dojo-work/03-drizzle-queries/
├── package.json          # drizzle-orm, better-sqlite3, tsx (devDep)
├── tsconfig.json
├── src/
│   ├── schema.ts         # Drizzle table definitions — authors + posts
│   ├── db.ts             # createDb() + createTrackedDb() helpers
│   ├── seed.ts           # seeds 3 authors and 5 posts
│   └── queries.ts        # three stubs — implement these
└── test/
    └── sample.test.ts    # visible: confirms getPostsByAuthor compiles and runs
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/03-drizzle-queries
npm install
```

## Mission

Implement the three functions in `src/queries.ts`:

### 1. `getPostsByAuthor(db, authorId)` → `Post[]`

A straightforward typed filter. No N+1 risk here — it's a single WHERE query. Getting the return type right (`Post[]`) is the point.

### 2. `getAuthorsWithPosts(db)` → `Array<{ author: Author; posts: Post[] }>`

This is the N+1 fix. The naive approach:
```ts
const all = db.select().from(authors).all()
return all.map(author => ({
  author,
  posts: db.select().from(posts).where(eq(posts.authorId, author.id)).all()
}))
```
…fires N+1 queries. Replace it with a single LEFT JOIN that fetches everything at once, then group the flat rows into the nested structure.

### 3. `createAuthorWithPost(db, authorData, postData)` → `{ author, post }`

Insert a new author and their first post atomically. `db.transaction(tx => {...})` wraps both inserts in a single SQLite transaction — if either fails, both roll back.

## What `verify.sh` checks

| Check | Details |
|-------|---------|
| `getPostsByAuthor` returns correct posts | Alice (id 1 after seed) has 2 posts |
| `getPostsByAuthor` on unknown author | Returns `[]`, not an error |
| `getAuthorsWithPosts` returns full structure | 3 authors, Alice has 2 posts, Carol has 1 |
| `getAuthorsWithPosts` uses exactly 1 SQL query | Via `better-sqlite3`'s `verbose` callback — N+1 fails this |
| `createAuthorWithPost` inserts both records | `post.authorId === author.id`, both in DB after call |

## Drizzle JOIN API

```ts
import { eq } from 'drizzle-orm'

// Flat result: { authors: Author, posts: Post | null }[]
const rows = db
  .select()
  .from(authors)
  .leftJoin(posts, eq(posts.authorId, authors.id))
  .all()

// Group by author:
const map = new Map<number, { author: Author; posts: Post[] }>()
for (const row of rows) {
  if (!map.has(row.authors.id)) {
    map.set(row.authors.id, { author: row.authors, posts: [] })
  }
  if (row.posts) map.get(row.authors.id)!.posts.push(row.posts)
}
return Array.from(map.values())
```

Note: the column names in the result object match the *TypeScript property names* from the schema (camelCase), not the SQL column names (snake_case).

## Debugging

**Symptom:** TypeScript error on `row.posts.authorId` — property does not exist.
**Cause:** With a LEFT JOIN, the right-hand table columns can be `null`. The type is `Post | null`.
**Fix:** Add a null check: `if (row.posts) { ... }` before accessing `row.posts.authorId`.

**Symptom:** `getAuthorsWithPosts` returns correct data but query count is 2 instead of 1.
**Cause:** Drizzle sometimes issues a lightweight schema introspection query on first use. More likely: the function is calling `.all()` on the join result and then running a second query somewhere in the grouping loop.
**Fix:** Confirm the loop does NOT call `db.select()` — it should only iterate the in-memory `rows` array.

**Symptom:** `createAuthorWithPost` inserts the author but throws on the post insert, leaving an orphaned author row.
**Cause:** The inserts are not wrapped in `db.transaction()`. Each insert is auto-committed separately.
**Fix:** `return db.transaction(tx => { const author = tx.insert(...).values(...).returning().get()!; const post = tx.insert(...).values({ ...postData, authorId: author.id }).returning().get()!; return { author, post } })`

> **War story.** A content management system migrated from raw SQL to an ORM "to make queries safer." Three months later, a new developer added a feature that loaded a user's posts — one ORM call that looked innocent: `users.map(u => u.posts)`. Under the hood it fired one `SELECT` per user. At 200 users × 1 ms DB roundtrip = 200 ms added to every page load. The fix was a ten-line JOIN. The lesson: an ORM hides SQL but doesn't hide the query count. Always check the query log after you ship a new read path.

## Verify

```bash
bash courses/course-33-node-backend-scale/challenges/03-drizzle-queries/verify.sh
```

All five checks green → flag printed.
