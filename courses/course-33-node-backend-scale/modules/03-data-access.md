# Data Access with Drizzle/Prisma

> **Module 03 · Course 33** — The database is where most Node.js services spend their latency budget. This module covers the patterns that separate "it works in dev" from "it works under 500 req/s in production": schema as code so your types match your schema without drift, migrations that don't destroy data, N+1 queries (the silent killer that adds 200 extra queries to a list endpoint), and connection pooling — because opening a new DB connection per request is how you exhaust Postgres at 50 users.

You already query a database. This is fast on "SELECT * FROM" and slow on the operational details that cause 3 am incidents.

---

## Schema as code

In a type-safe stack, the database schema and the TypeScript types for query results should be the same artefact — not two things kept in sync by convention.

**Without schema-as-code:**

```
SQL migration file        →  database columns
↓ manual re-type            ↓
TypeScript interface      →  query result shape
```

These two sides drift. Someone adds a column to the migration, forgets to update the interface, and the type lies for months until a production crash surfaces it.

**With schema-as-code:**

```
TypeScript schema file  →  generated migration SQL  →  database columns
↓ inferred automatically                                ↓
TypeScript types        ←─────────────────────────────  query result shape
```

One source of truth; the types are derived from it.

### Drizzle schema

Drizzle schemas are plain TypeScript. Column types map 1:1 to Postgres/SQLite/MySQL types, and query results are typed exactly as the schema declares:

```ts
// schema.ts
import { pgTable, uuid, text, numeric, integer, timestamp, index } from 'drizzle-orm/pg-core';
import { relations } from 'drizzle-orm';

export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  email: text('email').notNull().unique(),
  name: text('name').notNull(),
  createdAt: timestamp('created_at').defaultNow().notNull(),
});

export const orders = pgTable(
  'orders',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    totalCents: integer('total_cents').notNull(),
    status: text('status', { enum: ['pending', 'paid', 'cancelled'] })
      .notNull()
      .default('pending'),
    createdAt: timestamp('created_at').defaultNow().notNull(),
  },
  (table) => ({
    userIdIdx: index('orders_user_id_idx').on(table.userId),
  }),
);

// Relations — used by Drizzle's relational query API
export const usersRelations = relations(users, ({ many }) => ({
  orders: many(orders),
}));

export const ordersRelations = relations(orders, ({ one }) => ({
  user: one(users, { fields: [orders.userId], references: [users.id] }),
}));
```

The inferred TypeScript type for a row:

```ts
import { InferSelectModel, InferInsertModel } from 'drizzle-orm';

type User = InferSelectModel<typeof users>;
// { id: string; email: string; name: string; createdAt: Date }

type NewUser = InferInsertModel<typeof users>;
// { id?: string; email: string; name: string; createdAt?: Date }
```

No hand-written interfaces. Schema change → types update automatically on next `tsc`.

---

## Migrations: push vs migrate

Two workflows; use them in different contexts:

| Workflow | Command | When to use |
|----------|---------|-------------|
| `push` (Drizzle) / `db push` (Prisma) | `drizzle-kit push` | Local development only — overwrites the DB to match the schema, **no migration files** |
| `generate` + `migrate` | `drizzle-kit generate` then `drizzle-kit migrate` | CI/CD and production — creates a SQL migration file, applies it as a transaction |

**Never run `push` against a database that has data you care about.** `push` may drop columns or tables to match the schema. It is the "blow it up and rebuild" workflow, which is fine on a local dev DB and catastrophic anywhere else.

The production-safe workflow:

```bash
# 1. Change the schema in schema.ts
# 2. Generate the migration SQL (committed to git)
npx drizzle-kit generate --out ./drizzle/migrations --schema ./src/schema.ts

# 3. Review the generated SQL in ./drizzle/migrations/0003_add_orders_status.sql
# 4. Apply it (run by your deployment pipeline, not by hand)
npx drizzle-kit migrate
```

The migration file is a first-class commit artefact. Code review it just like application code. A `DROP COLUMN` in a migration needs a product decision, not a one-liner fix.

**Migration rollback** is not automatic in most SQL databases. Write a down-migration manually, or use column renaming strategies to preserve data across multiple deploys (add new column → backfill → switch code → remove old column as a separate deploy).

---

## Querying with Drizzle

Drizzle has two query APIs: a **SQL-like core API** and a higher-level **relational API** (`.query`). Both return typed results.

```ts
import { drizzle } from 'drizzle-orm/node-postgres';
import { eq, and, gt, desc, sql } from 'drizzle-orm';
import { Pool } from 'pg';
import * as schema from './schema';

const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 10 });
const db = drizzle(pool, { schema });

// SELECT with filter and ordering
const recentOrders = await db
  .select()
  .from(schema.orders)
  .where(and(eq(schema.orders.userId, userId), eq(schema.orders.status, 'pending')))
  .orderBy(desc(schema.orders.createdAt))
  .limit(20);
// recentOrders: Array<{ id: string; userId: string; totalCents: number; status: "pending" | "paid" | "cancelled"; createdAt: Date }>

// INSERT returning the inserted row
const [newOrder] = await db
  .insert(schema.orders)
  .values({ userId, totalCents: 4999, status: 'pending' })
  .returning();

// UPDATE
await db
  .update(schema.orders)
  .set({ status: 'paid' })
  .where(eq(schema.orders.id, orderId));

// Relational query — fetches user + orders in one query (JOIN under the hood)
const userWithOrders = await db.query.users.findFirst({
  where: eq(schema.users.id, userId),
  with: {
    orders: {
      where: eq(schema.orders.status, 'paid'),
      orderBy: desc(schema.orders.createdAt),
      limit: 10,
    },
  },
});
// userWithOrders.orders is typed as Order[]
```

---

## Transactions

A transaction guarantees that either all operations succeed or none of them are committed. Use one whenever multiple writes must be atomic:

```ts
// Drizzle transaction — db.transaction() passes a tx object that shares the connection
const result = await db.transaction(async (tx) => {
  // Deduct from the sender
  const [sender] = await tx
    .update(schema.wallets)
    .set({ balanceCents: sql`${schema.wallets.balanceCents} - ${amount}` })
    .where(
      and(
        eq(schema.wallets.userId, senderId),
        gt(schema.wallets.balanceCents, amount), // optimistic check inside tx
      ),
    )
    .returning();

  if (!sender) {
    tx.rollback(); // throws — Drizzle rolls back the tx
  }

  // Credit the recipient
  await tx
    .update(schema.wallets)
    .set({ balanceCents: sql`${schema.wallets.balanceCents} + ${amount}` })
    .where(eq(schema.wallets.userId, recipientId));

  // Log the transfer
  await tx.insert(schema.transfers).values({ senderId, recipientId, amountCents: amount });

  return sender;
});
```

> **Transactions must use the same connection.** This is why Drizzle's `db.transaction()` passes a `tx` object — every operation on `tx` is routed to the same underlying pool connection that holds the transaction open. Using `db` (the pool) inside a transaction block would silently use a different connection and not be part of the transaction.

---

## The N+1 problem

N+1 is the most common database performance problem in ORMs and the hardest to spot without query logging:

```ts
// Fetching 50 users, then their orders: 1 + 50 = 51 queries
const users = await db.select().from(schema.users).limit(50); // 1 query

for (const user of users) {
  const orders = await db
    .select()
    .from(schema.orders)
    .where(eq(schema.orders.userId, user.id)); // 1 query per user = 50 queries
  console.log(`${user.name}: ${orders.length} orders`);
}
```

The fix is a JOIN (or Drizzle's relational API which generates the JOIN for you):

```ts
// Option 1: explicit join — one query
const usersWithOrderCount = await db
  .select({
    userId: schema.users.id,
    name: schema.users.name,
    orderCount: sql<number>`count(${schema.orders.id})::int`.as('order_count'),
  })
  .from(schema.users)
  .leftJoin(schema.orders, eq(schema.orders.userId, schema.users.id))
  .groupBy(schema.users.id, schema.users.name)
  .limit(50);

// Option 2: Drizzle relational API — also one query (a JOIN internally)
const usersWithOrders = await db.query.users.findMany({
  limit: 50,
  with: { orders: true },
});
```

**How to detect N+1 in practice:**

```ts
// Enable query logging in Drizzle during development
const db = drizzle(pool, {
  schema,
  logger: {
    logQuery(query, params) {
      console.log('[SQL]', query, params);
    },
  },
});
// If you see the same query repeated N times with different IDs, you have N+1
```

For Prisma, set `log: ['query']` in the client constructor. For production, use `pg`'s `query` event or a proxy like `pgBouncer` with query statistics enabled.

---

## Connection pooling

Every Postgres connection consumes ~5 MB of RAM on the server and requires a process context. Opening a new connection per HTTP request is the fastest path to exhausting Postgres's `max_connections` limit (default 100 on many hosted instances):

```
Without pooling (naive):
Request 1  ──▶  open conn ──▶  query ──▶  close conn
Request 2  ──▶  open conn ──▶  query ──▶  close conn   (100-500ms overhead)
...
Request 101 ──▶  FATAL: sorry, too many clients already

With pooling (correct):
┌─────────────────────────────────────────────────────┐
│              Connection Pool (max: 10)              │
│   conn1  conn2  conn3  ...  conn10                  │
│   [idle] [busy] [idle]      [idle]                  │
└─────────────────────────────────────────────────────┘
Request N ──▶ borrow idle conn ──▶ query ──▶ return conn
              (microseconds, not milliseconds)
```

```ts
import { Pool } from 'pg';

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 10,              // maximum connections in the pool
  idleTimeoutMillis: 30_000,   // close idle connections after 30s
  connectionTimeoutMillis: 2_000, // fail fast if no connection available in 2s
});

// Monitor pool health — log if you're exhausting connections
pool.on('connect', () => {
  console.log(`Pool: new connection opened. Total: ${pool.totalCount}`);
});
pool.on('error', (err) => {
  console.error('Unexpected error on idle client', err);
});
```

The right `max` value depends on your Postgres `max_connections` and the number of Node.js processes. A rule of thumb: `max_connections / number_of_node_processes - 5` (leave headroom for migrations, monitoring, and your own psql queries).

For serverless environments (Vercel Edge, Lambda) where each function invocation creates its own process, use a connection proxy like [PgBouncer](https://www.pgbouncer.org) or [Neon's connection pooling](https://neon.tech/docs/connect/connection-pooling), which maintain a shared pool of persistent Postgres connections and multiplex short-lived function connections against them.

---

## Prepared statements

Prepared statements compile a query once and let Postgres reuse the execution plan. They also prevent SQL injection by separating the query structure from the parameter values:

```ts
// Drizzle uses prepared statements by default for parameterised queries
// Explicit prepared statement — useful for a hot loop
import { sql, placeholder } from 'drizzle-orm';

const prepared = db
  .select()
  .from(schema.orders)
  .where(eq(schema.orders.userId, placeholder('userId')))
  .orderBy(desc(schema.orders.createdAt))
  .limit(20)
  .prepare('get_recent_orders');

// Called many times — the plan is cached on the first execution
const orders = await prepared.execute({ userId: 'user-123' });
```

For raw `pg`, prepared statements are equally simple:

```ts
// Parameterized query — $1, $2 etc. are never interpolated into the query string
const res = await pool.query(
  'SELECT * FROM orders WHERE user_id = $1 AND status = $2',
  [userId, 'pending'],
);
// This is safe from SQL injection regardless of what userId contains
```

> **Never interpolate user input into a query string.** `WHERE id = '${req.params.id}'` is SQL injection. `WHERE id = $1` with `[req.params.id]` as the parameter array is safe. Drizzle and Prisma always use parameterised queries internally — the risk is only present if you reach for `db.execute(sql.raw(userInput))`.

---

## Drizzle vs Prisma tradeoffs

Both are excellent choices. The decision turns on your priorities:

| Dimension | Drizzle | Prisma |
|-----------|---------|--------|
| Query style | SQL-like API — you write what Drizzle executes | Model-based API — Prisma generates SQL from your intent |
| Bundle size | ~8 kB core | ~20 MB+ (includes query engine binary) |
| Edge / serverless | Yes — no binary engine, native `pg` drivers | Requires Prisma Accelerate or `@prisma/adapter-*` for true edge |
| Raw SQL escape hatch | Easy — `sql\`...\`` is first-class | Possible but verbose (`$queryRaw`) |
| Migrations | `drizzle-kit generate/migrate` | `prisma migrate dev/deploy` — more opinionated |
| Relations / includes | Relational API (explicit) | `include` / `select` (magic, can surprise) |
| Lazy loading | No | Yes (`.connect()`) — a common N+1 trap |
| Maturity | Newer (2022+) but fast-growing | Mature (2019+) large ecosystem |
| Best fit for | Lean APIs, edge deployments, teams comfortable with SQL | Rapid prototyping, teams that prefer model-centric thinking |

For this course and the challenges ahead: **Drizzle** is the default choice — it runs without a binary, fits Turso/libSQL cleanly, and its explicit SQL-like API makes it easier to reason about what queries run.

---

## Debugging data access

### Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| List endpoint: correct data but N×slower than expected; query count scales with result set | N+1 — each row triggers an extra query | Enable query logging; restructure with JOIN or relational API |
| `Error: sorry, too many clients already` | Pool exhausted — more concurrent requests than pool `max` | Raise pool `max` or reduce concurrent Node processes; add `connectionTimeoutMillis` |
| TypeScript types correct but production returns wrong column values | Migration applied partially (interrupted) or schema.ts edited without generating a migration | Check `drizzle-kit status`; inspect migration history table |
| `undefined` or missing fields after `include` in Prisma | Lazy-loading: relation not loaded because `include` was omitted | Explicitly add `include: { orders: true }` to every query that needs it; avoid re-fetching |
| Slow queries that are fast in isolation; query plan looks correct | Connection under transaction held too long — blocks other queries waiting on row-level locks | Keep transactions short; move non-DB work outside; use `SELECT ... FOR UPDATE SKIP LOCKED` for queue patterns |

### Diagnosing N+1

The fastest diagnosis is a query counter. In development, wrap your Drizzle instance:

```ts
let queryCount = 0;
const db = drizzle(pool, {
  schema,
  logger: {
    logQuery(query) {
      queryCount++;
      if (process.env.NODE_ENV === 'development') {
        console.log(`[Q${queryCount}]`, query.slice(0, 80));
      }
    },
  },
});

// After a request handler runs, if queryCount > 5, investigate
```

For production, use `pg-query-observer` or enable `log_min_duration_statement = 0` in Postgres (`postgresql.conf`) temporarily and look at the `pg_stat_statements` view:

```sql
SELECT query, calls, total_exec_time / calls AS avg_ms
FROM pg_stat_statements
ORDER BY calls DESC
LIMIT 20;
```

A query with `calls` in the thousands and `avg_ms` under 1 ms is N+1 — harmless individually, devastating in aggregate.

### Diagnosing pool exhaustion

```ts
// Add periodic pool stats logging
setInterval(() => {
  console.log({
    total: pool.totalCount,    // total open connections
    idle: pool.idleCount,      // connections waiting for a query
    waiting: pool.waitingCount, // requests waiting for a free connection
  });
}, 5000);

// If waitingCount > 0 consistently, you are pool-exhausted
// Options:
// 1. Increase pool max (check Postgres max_connections first)
// 2. Reduce query duration (the connections are held longer than necessary)
// 3. Add PgBouncer in transaction-pooling mode
```

### Diagnosing migration drift

Drift happens when someone applies a manual `ALTER TABLE` directly to a database and the migration history no longer matches the actual schema:

```bash
# Drizzle: compare the current schema to the migration history
npx drizzle-kit check --schema ./src/schema.ts

# Detect the delta manually
npx drizzle-kit introspect --out ./drizzle/introspected
# compare introspected/schema.ts with your src/schema.ts
```

The correct fix is a new migration that brings the history back into sync, not editing old migration files.

> **War story.** A team I consulted for had a `/admin/users` list endpoint that was working perfectly — all data correct, clean TypeScript types, 200 OK. But it was 2 seconds for a list of 100 users. Query logging revealed 101 queries: one for the users list, then one `SELECT * FROM roles WHERE user_id = $1` for each user. The ORM's relational query helper had been written as a `for` loop with individual `findUnique` calls because the original developer found the `include` syntax confusing. We added `with: { role: true }` to the single `findMany` call. The endpoint went from 2 seconds to 80 ms. The lesson: a list endpoint that does individual database calls per item is always an N+1, regardless of how many layers of abstraction hide it.

---

## Checkpoint

You are ready for the challenges when you can, without looking anything up:

1. Explain why schema-as-code prevents type drift and how `InferSelectModel` replaces a manually maintained interface.
2. Describe the difference between `drizzle-kit push` and `drizzle-kit generate` + `migrate` — and name the one context where `push` is acceptable.
3. Write a Drizzle query that fetches the last 20 orders for a user with status `'pending'`, ordered by `createdAt` descending.
4. Write a transaction that transfers `amount` from one wallet to another atomically and rolls back if the sender doesn't have sufficient balance.
5. Identify N+1 in a code snippet by reading the query log output and write the JOIN-based replacement.
6. Explain why you must never do `await db.query()` inside `db.transaction(async (tx) => { ... })` — only `tx.query()`.
7. Calculate the maximum pool `max` value for a service with 4 Node.js processes if Postgres `max_connections` is 50 (leave 10 reserved).
8. Explain in one sentence what a prepared statement does that an ad-hoc query does not — and why it matters for security, not just performance.

➡ Next up: **Background Jobs & Queues** — why some work should never happen inside an HTTP request, and how BullMQ + Redis gives you durable, retriable, monitorable job execution.
