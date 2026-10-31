import Database from 'better-sqlite3';
import { drizzle } from 'drizzle-orm/better-sqlite3';
import { sqliteTable, text, integer } from 'drizzle-orm/sqlite-core';
import { eq } from 'drizzle-orm';
import path from 'node:path';
import fs from 'node:fs';

export const progress = sqliteTable('progress', {
  challengeId: text('challenge_id').primaryKey(),
  courseId: text('course_id').notNull(),
  solved: integer('solved').notNull().default(0),
  attempts: integer('attempts').notNull().default(0),
  solvedAt: text('solved_at'),
});

export const submissions = sqliteTable('submissions', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  courseId: text('course_id').notNull(),
  challengeId: text('challenge_id').notNull(),
  correct: integer('correct').notNull(),
  createdAt: text('created_at').notNull(),
});

/**
 * Lazy singleton. The DB is opened on first *use*, never at module import —
 * otherwise `next build` (which imports every page module across parallel
 * workers) would open the file N times at once and die with SQLITE_BUSY.
 */
let _db: ReturnType<typeof drizzle> | null = null;

function getDb() {
  if (_db) return _db;
  const dataDir = path.join(process.cwd(), '.data');
  fs.mkdirSync(dataDir, { recursive: true });
  const sqlite = new Database(path.join(dataDir, 'dojo.db'));
  sqlite.pragma('journal_mode = WAL');
  sqlite.pragma('busy_timeout = 5000');
  sqlite.exec(`
    CREATE TABLE IF NOT EXISTS progress (
      challenge_id TEXT PRIMARY KEY,
      course_id    TEXT NOT NULL,
      solved       INTEGER NOT NULL DEFAULT 0,
      attempts     INTEGER NOT NULL DEFAULT 0,
      solved_at    TEXT
    );
    CREATE TABLE IF NOT EXISTS submissions (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      course_id    TEXT NOT NULL,
      challenge_id TEXT NOT NULL,
      correct      INTEGER NOT NULL,
      created_at   TEXT NOT NULL
    );
  `);
  _db = drizzle(sqlite, { schema: { progress, submissions } });
  return _db;
}

/** Stable per-challenge key used across tables and the UI. */
export function challengeKey(courseId: string, slug: string): string {
  return `${courseId}:${slug}`;
}

/** Map of challengeKey -> true for every solved challenge. */
export function getSolvedMap(): Record<string, boolean> {
  const rows = getDb().select().from(progress).where(eq(progress.solved, 1)).all();
  const map: Record<string, boolean> = {};
  for (const r of rows) map[r.challengeId] = true;
  return map;
}

export function isSolved(challengeId: string): boolean {
  const row = getDb().select().from(progress).where(eq(progress.challengeId, challengeId)).get();
  return !!row && row.solved === 1;
}

/** Record an attempt; mark solved (and stamp solvedAt) on first correct answer. */
export function recordAttempt(courseId: string, challengeId: string, correct: boolean): void {
  const db = getDb();
  const now = new Date().toISOString();
  db.insert(submissions)
    .values({ courseId, challengeId, correct: correct ? 1 : 0, createdAt: now })
    .run();

  const existing = db.select().from(progress).where(eq(progress.challengeId, challengeId)).get();
  if (existing) {
    const nowSolved = existing.solved === 1 || correct;
    db.update(progress)
      .set({
        attempts: existing.attempts + 1,
        solved: nowSolved ? 1 : 0,
        solvedAt: existing.solvedAt ?? (correct ? now : null),
      })
      .where(eq(progress.challengeId, challengeId))
      .run();
  } else {
    db.insert(progress)
      .values({
        challengeId,
        courseId,
        attempts: 1,
        solved: correct ? 1 : 0,
        solvedAt: correct ? now : null,
      })
      .run();
  }
}
