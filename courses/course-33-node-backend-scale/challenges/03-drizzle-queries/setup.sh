#!/usr/bin/env bash
# Plants the "Typed Queries and N+1 Prevention" TypeScript + Drizzle project.
# Idempotent — re-running overwrites source files but preserves node_modules.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/03-drizzle-queries"
mkdir -p "$WORK/src" "$WORK/test"

# ── package.json ──────────────────────────────────────────────────────────────
cat > "$WORK/package.json" << 'EOF'
{
  "name": "drizzle-queries",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "test": "tsx --test test/sample.test.ts"
  },
  "dependencies": {
    "better-sqlite3": "9.6.0",
    "drizzle-orm": "0.31.2"
  },
  "devDependencies": {
    "@types/better-sqlite3": "7.6.11",
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

# ── src/schema.ts ─────────────────────────────────────────────────────────────
cat > "$WORK/src/schema.ts" << 'EOF'
import { sqliteTable, integer, text } from 'drizzle-orm/sqlite-core'

export const authors = sqliteTable('authors', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  name: text('name').notNull(),
  email: text('email').notNull().unique(),
})

export const posts = sqliteTable('posts', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  title: text('title').notNull(),
  body: text('body').notNull(),
  authorId: integer('author_id').notNull().references(() => authors.id),
})

// Inferred types — the Drizzle equivalent of Zod's z.infer<typeof Schema>
export type Author = typeof authors.$inferSelect
export type NewAuthor = typeof authors.$inferInsert
export type Post = typeof posts.$inferSelect
export type NewPost = typeof posts.$inferInsert
EOF

# ── src/db.ts ─────────────────────────────────────────────────────────────────
cat > "$WORK/src/db.ts" << 'EOF'
import Database from 'better-sqlite3'
import { drizzle } from 'drizzle-orm/better-sqlite3'
import * as schema from './schema.ts'

const CREATE_SQL = `
  CREATE TABLE IF NOT EXISTS authors (
    id    INTEGER PRIMARY KEY AUTOINCREMENT,
    name  TEXT NOT NULL,
    email TEXT NOT NULL UNIQUE
  );
  CREATE TABLE IF NOT EXISTS posts (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    title     TEXT NOT NULL,
    body      TEXT NOT NULL,
    author_id INTEGER NOT NULL REFERENCES authors(id)
  );
`

// Plain DB — no query tracking.
export function createDb() {
  const sqlite = new Database(':memory:')
  sqlite.exec(CREATE_SQL)
  return drizzle(sqlite, { schema })
}

// Tracked DB — calls onQuery for every SQL statement executed.
// Use resetCount/getCount to measure how many queries a function issues.
export function createTrackedDb() {
  let count = 0
  const sqlite = new Database(':memory:', {
    verbose: () => { count++ },
  })
  sqlite.exec(CREATE_SQL)
  const db = drizzle(sqlite, { schema })
  return {
    db,
    resetCount: () => { count = 0 },
    getCount: () => count,
  }
}

export type DB = ReturnType<typeof createDb>
EOF

# ── src/seed.ts ───────────────────────────────────────────────────────────────
cat > "$WORK/src/seed.ts" << 'EOF'
import { authors, posts } from './schema.ts'
import type { DB } from './db.ts'

// Seeds 3 authors and 5 posts into an existing DB.
// Returns the inserted author rows so tests can reference their ids.
export function seed(db: DB) {
  const inserted = db
    .insert(authors)
    .values([
      { name: 'Alice', email: 'alice@example.com' },
      { name: 'Bob',   email: 'bob@example.com' },
      { name: 'Carol', email: 'carol@example.com' },
    ])
    .returning()
    .all()

  const [alice, bob, carol] = inserted

  db.insert(posts)
    .values([
      { title: 'Hello World',        body: 'My first post',              authorId: alice.id },
      { title: 'TypeScript Tips',    body: 'Always enable strict mode',  authorId: alice.id },
      { title: 'Node Internals',     body: 'The event loop explained',   authorId: bob.id },
      { title: 'ORM vs Raw SQL',     body: 'It depends on the context',  authorId: bob.id },
      { title: 'Quick Update',       body: 'Short post from Carol',      authorId: carol.id },
    ])
    .run()

  return { alice, bob, carol }
}
EOF

# ── src/queries.ts — skeleton ─────────────────────────────────────────────────
cat > "$WORK/src/queries.ts" << 'EOF'
import { eq } from 'drizzle-orm'
import { authors, posts } from './schema.ts'
import type { Author, Post, NewAuthor, NewPost } from './schema.ts'
import type { DB } from './db.ts'

// Returns all posts written by the given author.
// Implement as a single typed WHERE query — no N+1 possible here.
export function getPostsByAuthor(db: DB, authorId: number): Post[] {
  // TODO: db.select().from(posts).where(eq(posts.authorId, authorId)).all()
  throw new Error('not implemented')
}

// Returns every author together with their posts in a SINGLE query.
// A naive loop that calls db.select().from(posts).where(...) per author is N+1 — avoid it.
// Use a LEFT JOIN and group the flat result rows by author.id.
export function getAuthorsWithPosts(db: DB): Array<{ author: Author; posts: Post[] }> {
  // TODO: db.select().from(authors).leftJoin(posts, eq(posts.authorId, authors.id)).all()
  //       then group rows by author.id into { author, posts[] }
  throw new Error('not implemented')
}

// Inserts a new author and their first post atomically.
// Both inserts must be inside a single db.transaction() — if the post insert fails,
// the author insert must also be rolled back.
export function createAuthorWithPost(
  db: DB,
  authorData: NewAuthor,
  postData: Omit<NewPost, 'authorId'>,
): { author: Author; post: Post } {
  // TODO: db.transaction(tx => {
  //   const author = tx.insert(authors).values(authorData).returning().get()!
  //   const post   = tx.insert(posts).values({ ...postData, authorId: author.id }).returning().get()!
  //   return { author, post }
  // })
  throw new Error('not implemented')
}
EOF

# ── test/sample.test.ts — visible sample test ─────────────────────────────────
cat > "$WORK/test/sample.test.ts" << 'EOF'
// sample.test.ts — run: npm test   (or: npx tsx --test test/sample.test.ts)
// Confirms getPostsByAuthor compiles, runs, and returns the right count.
import { test, before } from 'node:test'
import assert from 'node:assert/strict'
import { createDb, type DB } from '../src/db.ts'
import { seed } from '../src/seed.ts'
import { getPostsByAuthor } from '../src/queries.ts'

let db: DB

before(() => {
  db = createDb()
  seed(db)
})

// seed() inserts: Alice (2 posts), Bob (2 posts), Carol (1 post)
// AUTOINCREMENT assigns ids sequentially: Alice=1, Bob=2, Carol=3
test('getPostsByAuthor — Alice (id=1) has 2 posts', () => {
  const result = getPostsByAuthor(db, 1)
  assert.equal(result.length, 2, `expected 2 posts for Alice, got ${result.length}`)
})
EOF

# ── print next steps ──────────────────────────────────────────────────────────
echo
echo "Work directory : $WORK"
echo
echo "Task           : implement the three functions in src/queries.ts"
echo "                 — getPostsByAuthor, getAuthorsWithPosts (JOIN), createAuthorWithPost (tx)"
echo
echo "Prerequisites  :"
echo "  cd $WORK && npm install"
echo
echo "Run sample test: cd $WORK && npm test"
echo "Verify + flag  : bash courses/course-33-node-backend-scale/challenges/03-drizzle-queries/verify.sh"
