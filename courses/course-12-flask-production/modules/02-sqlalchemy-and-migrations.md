# SQLAlchemy & Migrations

> **Module 02 · Course 12** — SQLAlchemy's ORM is powerful enough to be dangerous. The parts most tutorials skip — the identity map, the unit of work, the difference between a detached and a persistent instance — are exactly the parts that produce bugs in production. Know the session lifecycle cold; everything else follows.

---

## Models & Relationships

Flask-SQLAlchemy 3.x wraps SQLAlchemy 2.x. Use the 2.x-style declarative base via `db.Model`:

```python
# app/models/user.py
from datetime import datetime, timezone
from app.extensions import db


class User(db.Model):
    __tablename__ = "users"

    id: db.Mapped[int] = db.mapped_column(primary_key=True)
    email: db.Mapped[str] = db.mapped_column(db.String(255), unique=True, nullable=False, index=True)
    password_hash: db.Mapped[str] = db.mapped_column(db.String(128), nullable=False)
    created_at: db.Mapped[datetime] = db.mapped_column(
        default=lambda: datetime.now(timezone.utc)
    )
    is_active: db.Mapped[bool] = db.mapped_column(default=True)

    posts: db.Mapped[list["Post"]] = db.relationship(
        "Post", back_populates="author", cascade="all, delete-orphan", lazy="select"
    )

    def __repr__(self) -> str:
        return f"<User {self.email}>"
```

```python
# app/models/post.py
from datetime import datetime, timezone
from app.extensions import db


class Post(db.Model):
    __tablename__ = "posts"

    id: db.Mapped[int] = db.mapped_column(primary_key=True)
    title: db.Mapped[str] = db.mapped_column(db.String(500), nullable=False)
    body: db.Mapped[str] = db.mapped_column(db.Text, nullable=False)
    author_id: db.Mapped[int] = db.mapped_column(db.ForeignKey("users.id"), nullable=False, index=True)
    created_at: db.Mapped[datetime] = db.mapped_column(
        default=lambda: datetime.now(timezone.utc)
    )

    author: db.Mapped["User"] = db.relationship("User", back_populates="posts")
```

Notes worth internalizing:
- `db.Mapped[T]` is the 2.x annotation style — it gives you type-checker support and makes `nullable` inferred from the type (`Optional[T]` → nullable). Use it; the older untyped `Column` style is still valid but gives you nothing for free.
- `index=True` on every foreign key and every column you filter or sort by. Forgetting this on `author_id` means your "all posts by user" query does a full table scan in production.
- `cascade="all, delete-orphan"` means deleting a `User` deletes their `Posts`. Be explicit. Default `cascade` is `save-update, merge` — not what you want for owned collections.

### Relationship loading strategies

| Strategy | SQL behaviour | Use when |
|----------|---------------|----------|
| `lazy="select"` (default) | N+1: one SELECT per accessed relationship | Accessing one related object on one parent |
| `lazy="joined"` | One query with a JOIN | You always need the related object with the parent |
| `lazy="subquery"` | One extra SELECT per loaded parent collection | Loading a collection for many parents (avoids Cartesian product) |
| `lazy="dynamic"` (deprecated 2.x) | Returns a query object, not a list | Don't use — replaced by `write_only` or explicit `db.select()` |
| `lazy="raise"` | Raises `MissingGreenlet` if accessed | Catch unintentional lazy loads in dev/test — forces explicit loading |

```python
# Explicit eager loading in the query — preferred over changing the model default
from sqlalchemy.orm import selectinload, joinedload

# selectinload: one extra SELECT (best for collections — no Cartesian product)
users = db.session.execute(
    db.select(User).options(selectinload(User.posts))
).scalars().all()

# joinedload: JOIN in the same SELECT (best for single related objects)
post = db.session.execute(
    db.select(Post).options(joinedload(Post.author)).where(Post.id == post_id)
).scalar_one()
```

---

## Sessions & the Unit of Work

SQLAlchemy's `Session` is not a database connection. It's an **identity map + unit of work**:

- **Identity map:** for any (class, primary key) pair, only one Python object exists within a session. `session.get(User, 1)` twice returns the same object.
- **Unit of work:** the session tracks every object you add, modify, or delete. On `commit()`, it issues the minimal SQL to make the database match in-memory state. On `rollback()`, it discards all tracked changes.

```
┌─────────────────────────────────── session ────────────────────────────────────┐
│                                                                                 │
│   transient   ──add()──►   pending   ──commit()──►  persistent                 │
│   (no id,                  (tracked,               (synced to DB,               │
│   no session)              not in DB)              has id, in identity map)     │
│                                                         │                       │
│                                                     expire_on_commit()          │
│                                                         │                       │
│                                                         ▼                       │
│                                                    expunged/closed              │
│                                                    ──────────────►  detached   │
│                                                                   (id exists,   │
│                                                                   no session)   │
└─────────────────────────────────────────────────────────────────────────────────┘
```

The lifecycle in a Flask request:

```python
@users_bp.post("/")
def create_user():
    data = request.get_json()
    user = User(email=data["email"], password_hash=hash_password(data["password"]))
    # transient → pending
    db.session.add(user)
    # pending → persistent: INSERT fires, user.id is populated
    db.session.commit()
    # after commit, SQLAlchemy marks attributes expired (lazy-reloads on next access)
    return jsonify({"id": user.id, "email": user.email}), 201
```

```python
@users_bp.delete("/<int:user_id>")
def delete_user(user_id: int):
    user = db.session.get(User, user_id)
    if user is None:
        return jsonify({"error": "not found"}), 404
    db.session.delete(user)
    db.session.commit()
    return "", 204
```

Flask-SQLAlchemy registers a `teardown_appcontext` hook that calls `db.session.remove()` after every request. `remove()` calls `close()` on the underlying session and returns it to the connection pool — you never call this manually inside a view function.

---

## Query Patterns & N+1

### Modern 2.x query style

```python
# Fetch one row by primary key — uses identity map if already loaded
user = db.session.get(User, user_id)

# Fetch one row by arbitrary condition — raises if zero or more than one result
user = db.session.execute(
    db.select(User).where(User.email == email)
).scalar_one()

# Fetch one or None
user = db.session.execute(
    db.select(User).where(User.email == email)
).scalar_one_or_none()

# Fetch many with filters, ordering, pagination
posts = db.session.execute(
    db.select(Post)
    .where(Post.author_id == user_id, Post.created_at >= cutoff)
    .order_by(Post.created_at.desc())
    .limit(20)
    .offset((page - 1) * 20)
).scalars().all()

# Count without loading objects
total = db.session.execute(
    db.select(db.func.count()).select_from(Post).where(Post.author_id == user_id)
).scalar_one()
```

Avoid the legacy `User.query.filter_by(...)` style — it's still supported but will be deprecated. `db.select()` composes, is type-checkable, and is the canonical 2.x path.

### The N+1 Problem

The most common ORM performance bug. A loop accesses a lazy relationship, triggering one extra SELECT per row:

```python
# BAD — N+1 queries: 1 SELECT for users + N SELECTs for user.posts
users = db.session.execute(db.select(User)).scalars().all()
for user in users:
    print(user.email, len(user.posts))   # lazy load fires here for each user
```

```python
# GOOD — 2 queries total: 1 for users + 1 subquery for all their posts
users = db.session.execute(
    db.select(User).options(selectinload(User.posts))
).scalars().all()
for user in users:
    print(user.email, len(user.posts))   # already loaded, no SQL
```

The fastest way to catch N+1 in development: set `SQLALCHEMY_ECHO = True` in `DevelopmentConfig`. Every SQL statement logs to stderr. If you see the same SELECT repeated N times with only the `WHERE id =` value changing, that's your N+1.

For production, use [sqlalchemy-utils](https://sqlalchemy-utils.readthedocs.io/) query counters in tests:

```python
# tests/test_users.py — assert query count stays bounded
def test_list_users_no_n_plus_one(client, db_session):
    # create 20 users with posts
    ...
    with db_session.no_autoflush:
        pass

    # SQLAlchemy provides event hooks for counting queries in tests
    query_count = 0
    from sqlalchemy import event
    @event.listens_for(db_session.get_bind(), "before_cursor_execute")
    def count_query(*args, **kwargs):
        nonlocal query_count
        query_count += 1

    response = client.get("/users")
    assert response.status_code == 200
    assert query_count <= 3   # 1 for users, 1 for posts via selectinload, 1 for count
```

---

## Flask-SQLAlchemy Integration Points

Flask-SQLAlchemy adds three things on top of raw SQLAlchemy:

1. **Scoped session.** `db.session` is a `scoped_session` bound to the application context. Each request gets its own session, automatically closed at request end. You never create sessions manually.
2. **`db.Model` base.** Wires `__tablename__` inference (class name → snake_case), binds to the current app's metadata.
3. **CLI integration.** `flask db` commands are added by Flask-Migrate (`db.init_app(app, db)` in `create_app`).

What Flask-SQLAlchemy does **not** do: query optimization, connection pool tuning, read replicas. For those you configure the SQLAlchemy engine directly:

```python
# app/config.py
class ProductionConfig(Config):
    SQLALCHEMY_DATABASE_URI: str = os.environ["DATABASE_URL"]
    SQLALCHEMY_ENGINE_OPTIONS: dict = {
        "pool_size": 10,
        "max_overflow": 20,
        "pool_pre_ping": True,   # detect stale connections — critical for Postgres under load
        "pool_recycle": 1800,    # recycle connections after 30 min
    }
```

`pool_pre_ping=True` is the single most important production setting. Without it, a `db.session.execute()` against a connection that the database server closed (idle timeout, restart) raises `OperationalError: server closed the connection unexpectedly`. With it, SQLAlchemy issues a lightweight `SELECT 1` before handing out a connection and discards dead ones transparently.

---

## Alembic Migrations

Flask-Migrate wraps Alembic. Alembic compares your model metadata to the live schema and generates migration scripts.

### Setup

```bash
# one-time per project
flask db init    # creates migrations/ directory with env.py, alembic.ini

# generate a migration after changing a model
flask db migrate -m "add posts table"   # autogenerates migrations/versions/<hash>_add_posts_table.py

# apply to the database
flask db upgrade

# roll back one version
flask db downgrade
```

### Reading and hardening autogenerated migrations

Autogenerate is useful but not perfect. Always read the generated file before running `flask db upgrade`:

```python
# migrations/versions/abc123_add_posts_table.py
def upgrade() -> None:
    op.create_table(
        "posts",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("title", sa.String(length=500), nullable=False),
        sa.Column("body", sa.Text(), nullable=False),
        sa.Column("author_id", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=True),
        sa.ForeignKeyConstraint(["author_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_posts_author_id"), "posts", ["author_id"], unique=False)
```

Things autogenerate misses or gets wrong:
- **`server_default` values** — often not detected as changes.
- **Renamed columns** — detected as drop + add (data loss). Use `op.alter_column()` instead.
- **Postgres-specific types** like `JSONB`, `ARRAY`, enums — verify the generated type.
- **Partial or expression indexes** — not autogenerated at all; write them by hand.

Write your own `downgrade()` properly — autogenerated downgrades that drop entire tables are dangerous. Prefer a safe down:

```python
def downgrade() -> None:
    op.drop_index(op.f("ix_posts_author_id"), table_name="posts")
    op.drop_table("posts")
```

### Multi-environment migration workflow

```bash
# Confirm which revision the DB is at
flask db current

# Confirm the head matches what's in migrations/versions/
flask db heads

# Check for uncommitted drift (model vs DB schema mismatch)
flask db check    # added in Flask-Migrate 4.0 — exits non-zero if drift detected
```

In CI: run `flask db check` before any tests that touch the database. A drift between model and migration is the most common source of "works on dev, breaks in staging" bugs.

---

## Debugging SQLAlchemy & Migrations

| Symptom | Cause | Fix |
|---------|-------|-----|
| `DetachedInstanceError: Instance <User> is not bound to a Session` | Accessed a lazy-loaded attribute on an object after the session was closed (e.g., after returning from a view, in a Celery task) | Either load the attribute within the session scope (`selectinload`, explicit attribute access before commit), or detach intentionally with `db.session.expunge()` + `make_transient()`, or use `expire_on_commit=False` on the session |
| Identical SELECT statement appears N times in `SQLALCHEMY_ECHO` output | N+1 lazy load — accessing a relationship in a loop without eager loading | Add `.options(selectinload(Model.relationship))` to the parent query |
| `flask db migrate` generates an empty migration | Model change wasn't imported into `migrations/env.py` — Alembic compares against what's in `db.metadata`, not the filesystem | Import all models in `app/__init__.py` or explicitly in `migrations/env.py` before `run_migrations_online()` |
| `(sqlite3.OperationalError) table "users" already exists` on `flask db upgrade` | Migration history in the DB is out of sync with the files (stamped at wrong revision, or DB was created via `db.create_all()` bypassing Alembic) | `flask db stamp head` to tell Alembic the schema is current; then `flask db upgrade` for future changes |
| `OperationalError: server closed the connection unexpectedly` under load | Stale connection from pool — DB server dropped an idle connection that SQLAlchemy didn't know about | Add `pool_pre_ping=True` to `SQLALCHEMY_ENGINE_OPTIONS` |
| `SAWarning: Column 'users.email' ... has no default` after adding a NOT NULL column | Adding a non-nullable column to a table with existing rows without a default | Add a `server_default` to the migration or migrate in two steps: add as nullable → backfill → alter to not-null |

### Exact commands

```bash
# See every SQL statement as Flask runs — critical for N+1 detection
SQLALCHEMY_ECHO=1 flask run

# Or set in config and run tests
FLASK_ENV=development pytest -s   # -s keeps stdout so ECHO logs are visible

# Check migration state
flask db current   # current revision applied to the DB
flask db heads     # latest revision in the migration files
flask db history   # full migration chain

# Generate with autogenerate and immediately review
flask db migrate -m "add user roles"
cat migrations/versions/$(ls -t migrations/versions/ | head -1)

# Apply only to staging first
DATABASE_URL=postgres://staging/app flask db upgrade

# Rollback one step safely
flask db downgrade -1

# Force-stamp the DB to a specific revision without running migrations (recovery)
flask db stamp <revision_id>
```

> **War story.** At SAP we had a migration that added a `NOT NULL` column with no default to a 3-million-row table. The autogenerated migration ran fine in development (empty table), ran fine in staging (100 rows, instant), and took 47 seconds in production — during which Postgres held a full `ACCESS EXCLUSIVE` lock on the table, making every API call that touched users time out. The fix was a three-step zero-downtime migration: (1) add the column as nullable, (2) backfill in batches of 10k with a plain `UPDATE`, (3) a separate migration to add the NOT NULL constraint. Alembic never tells you about lock acquisition. Before running any migration on a large table, check `pg_locks` in a psql session on staging under simulated load. One lock-wait query tells you more than any autogenerated script.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Write a `User` → `Post` one-to-many relationship with the correct `cascade`, `back_populates`, and a FK index.
2. Explain the session lifecycle states: transient, pending, persistent, detached.
3. Explain why Flask-SQLAlchemy's `teardown_appcontext` hook matters and what happens without it.
4. Write the same query in both the legacy `User.query` style and the modern `db.select()` style.
5. Identify an N+1 from `SQLALCHEMY_ECHO` output and fix it with `selectinload`.
6. Run `flask db migrate` + `flask db upgrade` and explain what `flask db check` tells you in CI.
7. Diagnose a `DetachedInstanceError` from a stack trace — name the exact line where the session boundary was crossed.
8. Write a safe migration for adding a NOT NULL column to a large table without a full table lock.

➡ Next: **Authentication: Sessions & JWT** — password hashing, Flask-Login, token refresh, CSRF, and scopes.
