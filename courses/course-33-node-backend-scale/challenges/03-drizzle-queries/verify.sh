#!/usr/bin/env bash
# Verifier for "Typed Queries and N+1 Prevention".
# Writes hidden tests, runs tsx --test, prints flag on all-pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/03-drizzle-queries"
FLAG='KUBE{joins_beat_n_plus_one}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]                 || fail "work directory missing — run setup.sh first"
[ -f "$WORK/src/queries.ts" ]  || fail "src/queries.ts not found — run setup.sh first"

cd "$WORK"
npm install --silent 2>/dev/null || npm install 2>&1 | tail -5

# ── write hidden test file ────────────────────────────────────────────────────
HIDDEN="$WORK/test/_verify_hidden.test.ts"
cat > "$HIDDEN" << 'TESTEOF'
import { test, before } from 'node:test'
import assert from 'node:assert/strict'
import { createDb, createTrackedDb, type DB } from '../src/db.ts'
import { seed } from '../src/seed.ts'
import { getPostsByAuthor, getAuthorsWithPosts, createAuthorWithPost } from '../src/queries.ts'

// ── plain DB for correctness tests ───────────────────────────────────────────
let db: DB

before(() => {
  db = createDb()
  seed(db)
})

test('getPostsByAuthor returns all posts for a given author', () => {
  const result = getPostsByAuthor(db, 1)  // Alice has 2 posts
  assert.equal(result.length, 2, `Alice (id=1) should have 2 posts, got ${result.length}`)
  assert.ok(
    result.every(p => p.authorId === 1),
    'every returned post must have authorId === 1'
  )
})

test('getPostsByAuthor returns empty array for unknown author', () => {
  const result = getPostsByAuthor(db, 99999)
  assert.deepEqual(result, [], 'unknown author should return [], not throw')
})

test('getAuthorsWithPosts returns all authors with correct post counts', () => {
  const result = getAuthorsWithPosts(db)
  assert.equal(result.length, 3, `expected 3 authors, got ${result.length}`)

  const alice = result.find(r => r.author.name === 'Alice')
  assert.ok(alice, 'Alice must appear in result')
  assert.equal(alice!.posts.length, 2, `Alice should have 2 posts, got ${alice!.posts.length}`)

  const bob = result.find(r => r.author.name === 'Bob')
  assert.ok(bob, 'Bob must appear in result')
  assert.equal(bob!.posts.length, 2, `Bob should have 2 posts, got ${bob!.posts.length}`)

  const carol = result.find(r => r.author.name === 'Carol')
  assert.ok(carol, 'Carol must appear in result')
  assert.equal(carol!.posts.length, 1, `Carol should have 1 post, got ${carol!.posts.length}`)
})

// ── tracked DB for the N+1 check ─────────────────────────────────────────────
test('getAuthorsWithPosts uses exactly 1 SQL query (no N+1)', () => {
  const { db: tdb, resetCount, getCount } = createTrackedDb()
  seed(tdb as unknown as DB)
  resetCount()  // ignore seed queries

  getAuthorsWithPosts(tdb as unknown as DB)

  const count = getCount()
  assert.equal(
    count, 1,
    `getAuthorsWithPosts fired ${count} SQL queries; expected exactly 1. ` +
    `Use a LEFT JOIN instead of a per-author SELECT.`
  )
})

// ── transaction test ──────────────────────────────────────────────────────────
test('createAuthorWithPost inserts both records with matching FK', () => {
  const before_count = getAuthorsWithPosts(db).length

  const { author, post } = createAuthorWithPost(
    db,
    { name: 'Dave', email: 'dave@example.com' },
    { title: 'Dave\'s First Post', body: 'Created in a transaction' }
  )

  assert.equal(typeof author.id, 'number', 'author.id must be a number')
  assert.equal(author.name, 'Dave')
  assert.equal(author.email, 'dave@example.com')
  assert.equal(typeof post.id, 'number', 'post.id must be a number')
  assert.equal(post.authorId, author.id, 'post.authorId must equal the new author.id')
  assert.equal(post.title, "Dave's First Post")

  const after_result = getAuthorsWithPosts(db)
  assert.equal(after_result.length, before_count + 1,
    'author count must increase by exactly 1 after createAuthorWithPost')
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
