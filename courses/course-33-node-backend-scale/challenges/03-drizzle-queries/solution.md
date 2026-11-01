# Solution — Typed Queries and N+1 Prevention

Complete `src/queries.ts`. Explanations below each function.

```typescript
import { eq } from 'drizzle-orm'
import { authors, posts } from './schema.ts'
import type { Author, Post, NewAuthor, NewPost } from './schema.ts'
import type { DB } from './db.ts'

export function getPostsByAuthor(db: DB, authorId: number): Post[] {
  return db
    .select()
    .from(posts)
    .where(eq(posts.authorId, authorId))
    .all()
}

export function getAuthorsWithPosts(db: DB): Array<{ author: Author; posts: Post[] }> {
  const rows = db
    .select()
    .from(authors)
    .leftJoin(posts, eq(posts.authorId, authors.id))
    .all()

  const map = new Map<number, { author: Author; posts: Post[] }>()
  for (const row of rows) {
    if (!map.has(row.authors.id)) {
      map.set(row.authors.id, { author: row.authors, posts: [] })
    }
    if (row.posts) {
      map.get(row.authors.id)!.posts.push(row.posts)
    }
  }
  return Array.from(map.values())
}

export function createAuthorWithPost(
  db: DB,
  authorData: NewAuthor,
  postData: Omit<NewPost, 'authorId'>,
): { author: Author; post: Post } {
  return db.transaction((tx) => {
    const author = tx.insert(authors).values(authorData).returning().get()!
    const post = tx
      .insert(posts)
      .values({ ...postData, authorId: author.id })
      .returning()
      .get()!
    return { author, post }
  })
}
```

## Why each piece is required

**`getPostsByAuthor` — typed `.where()` with `eq`.**
`eq(posts.authorId, authorId)` is Drizzle's type-safe equality operator. Unlike raw SQL `WHERE author_id = ?`, the TypeScript compiler verifies that `posts.authorId` is a column that exists on the `posts` table and that `authorId` is a compatible type (number). Renaming the column in the schema would cause a compile error at the call site — no silent mismatch.

**`getAuthorsWithPosts` — LEFT JOIN + in-memory grouping.**
The SQL produced by `.leftJoin(posts, eq(posts.authorId, authors.id))` is a single statement:
```sql
SELECT authors.*, posts.*
FROM authors
LEFT JOIN posts ON posts.author_id = authors.id
```
The result is a flat array of `{ authors: Author, posts: Post | null }` rows. An author with no posts still appears (as one row with `posts: null`). An author with two posts appears twice. The `Map` groups by `author.id` and accumulates posts. This is the standard relational-to-object mapping pattern that every ORM implements under the hood.

**Why LEFT JOIN, not INNER JOIN.**
An INNER JOIN would silently drop authors with zero posts. If an author has no posts yet, they disappear from the result. That's usually wrong — you'd show a user their profile with no posts visible, not remove them from the list entirely. Use INNER JOIN only when the relationship is guaranteed to exist (e.g., every order must have a customer).

**`createAuthorWithPost` — `db.transaction()`.**
`db.transaction(tx => {...})` wraps the callback in a single SQLite transaction. If anything inside throws, better-sqlite3 automatically rolls back. Without this, a duplicate-email constraint violation on the author insert would still leave a committed author row if you inserted the author first without a transaction. With the transaction, both succeed or neither does — the atomicity guarantee.

**`.returning().get()!` on insert.**
Drizzle's `.returning()` uses SQLite's `RETURNING` clause (available since SQLite 3.35, shipped with macOS 12+/Ubuntu 22+) to return the inserted row in the same statement. `.get()` returns the first (and only) row. The `!` non-null assertion is safe here because a successful INSERT always returns a row — if the insert fails, the transaction throws before reaching `.get()`.

## The N+1 pattern — mental model

```
N+1 queries (bad):                    1 query (good):
─────────────────────                 ───────────────
SELECT * FROM authors          →      SELECT a.*, p.*
  ↓ [Alice, Bob, Carol]                FROM authors a
SELECT * FROM posts WHERE authorId=1   LEFT JOIN posts p ON p.author_id = a.id
SELECT * FROM posts WHERE authorId=2
SELECT * FROM posts WHERE authorId=3  Single roundtrip. DB does the join.
                                      O(1) latency, not O(N).
```

The ORM makes it easy to write the N+1 version accidentally because it looks like a normal object property access. Tools like Drizzle's query log, `pg_stat_statements`, or a simple verbose callback (as used in `createTrackedDb`) make it visible.

## Hardening preview

For production use, add:
- **Indexes:** `CREATE INDEX posts_author_idx ON posts(author_id)` — the LEFT JOIN's ON clause needs this index to avoid a full table scan per author.
- **Pagination:** large result sets need `LIMIT`/`OFFSET` or keyset pagination.
- **Connection pooling:** better-sqlite3 is synchronous and single-connection; for concurrent Node processes use a pool library or switch to `@electric-sql/pglite` / Postgres.
- **Query logging in production:** wrap `createTrackedDb`'s verbose pattern with a structured logger and alert on queries that fire > N times per request.

## Apply and verify

```bash
cd ~/.kube-dojo-work/03-drizzle-queries
# Replace src/queries.ts with the solution above, then:
npm test
bash courses/course-33-node-backend-scale/challenges/03-drizzle-queries/verify.sh
```
