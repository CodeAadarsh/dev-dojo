# Async Data & Auth

> **Module 04 · Course 15** — An endpoint that awaits a database call while your connection pool is exhausted is just a slow 500 waiting to happen. This module wires async SQLAlchemy 2.0 correctly, then layers OAuth2 + JWT on top so you understand both halves of the auth handshake before you copy-paste them from a blog post.

You already know sync SQLAlchemy and you've seen JWTs in the wild. This module is about the gaps: why an async session inside a sync dependency silently deadlocks, how the connection pool becomes your bottleneck before your CPU does, and exactly where `alg:none` lets an attacker forge any token.

---

## Async SQLAlchemy 2.0 Sessions

### The engine and sessionmaker

```python
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession

DATABASE_URL = "postgresql+asyncpg://user:pass@localhost/db"

engine = create_async_engine(
    DATABASE_URL,
    pool_size=10,         # base connections kept open permanently
    max_overflow=20,      # burst capacity above pool_size; pool_size + max_overflow = hard max
    pool_timeout=30,      # seconds to wait for a free connection before TimeoutError
    pool_pre_ping=True,   # test connection health before use; catches stale conns after DB restart
    echo=False,
)

AsyncSessionLocal = async_sessionmaker(
    bind=engine,
    expire_on_commit=False,   # critical in async — see below
    autocommit=False,
    autoflush=False,
)
```

`pool_pre_ping=True` is the parameter you forget until you get a wall of
`Interface error: connection already closed` at 2 AM after a DB maintenance window.

`expire_on_commit=False` is the async gotcha most people hit once. By default SQLAlchemy expires
every attribute on commit, then reloads lazily on next access. Lazy loading is synchronous I/O —
it raises `MissingGreenlet` inside an `async` function. Disable expiry.

### The async session dependency

```python
from typing import AsyncGenerator
from sqlalchemy.ext.asyncio import AsyncSession

async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with AsyncSessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
```

`async with AsyncSessionLocal()` calls `session.close()` on exit — no manual cleanup.
The `try/commit/except/rollback` pattern means every successful request auto-commits and every
exception rolls back cleanly. Put this in `deps.py` and import it everywhere.

### Using it in a route

```python
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

router = APIRouter()

@router.get("/items/{item_id}")
async def get_item(item_id: int, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Item).where(Item.id == item_id))
    item = result.scalar_one_or_none()
    if not item:
        raise HTTPException(status_code=404)
    return item
```

SQLAlchemy 2.0's `select()` is always explicit. The ORM 1.x `session.query(Item)` style is
deprecated and does not work in async contexts — do not use it.

For relationships that need to come back in the same query, use eager loading:

```python
from sqlalchemy.orm import selectinload

result = await db.execute(
    select(User).where(User.id == user_id).options(selectinload(User.items))
)
```

`selectinload` issues a second `SELECT ... WHERE id IN (...)` query. It is async-safe.
`joinedload` issues a `JOIN` in the same query — also async-safe and better when you always
need the relationship. Never access a relationship without one of these; lazy loading in an async
context raises `MissingGreenlet` at runtime.

---

## Connection Pool Tuning

The pool is a fixed-size buffer of live DB connections. Get sizing wrong and you either waste
connections (the DB has limits too) or queue requests under load.

```
 Request 1 ──► acquire conn ──► await query ──► release conn
 Request 2 ──► acquire conn ──► await query ──► release conn
 ...
 Request 31 ──► (pool_size=10, max_overflow=20) = 30 connections in use
               blocks for pool_timeout seconds
               if nobody releases: raises sqlalchemy.exc.TimeoutError
```

Rules of thumb for a Gunicorn + uvicorn deployment:

| Scenario | Setting |
|----------|---------|
| Single process, low concurrency | `pool_size=5, max_overflow=10` |
| 4 Gunicorn workers, normal API | `pool_size=5, max_overflow=10` per process = 60 max total |
| High-throughput async service | `pool_size=10, max_overflow=20`; monitor active connections |
| Serverless / many instances | Use `NullPool` (no pooling); close on every request |

For PostgreSQL: `pool_size × worker_count × replica_count` must not exceed
`max_connections - 5` (reserve for ops). Check with `SHOW max_connections;`.

Monitoring query:

```sql
SELECT count(*), state FROM pg_stat_activity GROUP BY state;
-- 'idle in transaction' accumulating = sessions not committing/rolling back
-- 'active' spiking = real load or slow queries
```

---

## OAuth2 Password Flow + JWT

The OAuth2 password flow is a three-step handshake:

```
1. Client POSTs {username, password} to POST /auth/token
2. Server verifies, signs JWT, returns {"access_token": "...", "token_type": "bearer"}
3. Client sends "Authorization: Bearer <token>" on every subsequent request
```

FastAPI's `OAuth2PasswordBearer` handles step 3: it reads the header and injects the raw token
string into your dependency.

### Password hashing with passlib

```python
from passlib.context import CryptContext

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

def hash_password(plain: str) -> str:
    return pwd_context.hash(plain)

def verify_password(plain: str, hashed: str) -> bool:
    return pwd_context.verify(plain, hashed)
```

Always bcrypt. Never store plaintext. Never MD5 or SHA-1 — no work factor means a GPU can crack
an entire leaked database in hours.

### Issuing and verifying JWTs with PyJWT

```python
import jwt
from datetime import datetime, timedelta, timezone

SECRET_KEY = "change-me-in-prod-use-env-var"
ALGORITHM = "HS256"

def create_access_token(subject: str, expires_delta: timedelta = timedelta(minutes=30)) -> str:
    now = datetime.now(tz=timezone.utc)
    payload = {
        "sub": subject,
        "iat": now,
        "exp": now + expires_delta,
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)

def decode_access_token(token: str) -> dict:
    # ALWAYS pass algorithms= as a list — see Debugging section for why this matters
    return jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
```

`sub` = subject (your user identifier), `iat` = issued-at, `exp` = expiry. These are RFC 7519
registered claims — use them. PyJWT validates `exp` automatically on decode.

### The auth dependency chain

```python
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/token")

async def get_current_user(
    token: str = Depends(oauth2_scheme),
    db: AsyncSession = Depends(get_db),
) -> User:
    credentials_exc = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = decode_access_token(token)
        username: str | None = payload.get("sub")
        if not username:
            raise credentials_exc
    except jwt.ExpiredSignatureError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token expired",
            headers={"WWW-Authenticate": "Bearer"},
        )
    except jwt.InvalidTokenError:
        raise credentials_exc

    result = await db.execute(select(User).where(User.username == username))
    user = result.scalar_one_or_none()
    if not user:
        raise credentials_exc
    return user

# POST /auth/token handler
@router.post("/auth/token")
async def login(form: OAuth2PasswordRequestForm = Depends(), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User).where(User.username == form.username))
    user = result.scalar_one_or_none()
    if not user or not verify_password(form.password, user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect username or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    token = create_access_token(subject=user.username)
    return {"access_token": token, "token_type": "bearer"}
```

### Security scopes

When a single API has multiple privilege levels (read vs write vs admin), encode them as OAuth2
scopes instead of role-checking inside every handler:

```python
from fastapi.security import OAuth2PasswordBearer, SecurityScopes
from fastapi import Security

oauth2_scheme = OAuth2PasswordBearer(
    tokenUrl="/auth/token",
    scopes={"read:items": "Read items", "write:items": "Create or update items"},
)

async def get_current_user(
    security_scopes: SecurityScopes,
    token: str = Depends(oauth2_scheme),
    db: AsyncSession = Depends(get_db),
) -> User:
    # ... decode token as before ...
    token_scopes: list[str] = payload.get("scopes", [])
    for scope in security_scopes.scopes:
        if scope not in token_scopes:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Scope '{scope}' required",
            )
    # ... DB lookup ...

# Declare scope requirements at the route level:
@router.post("/items", dependencies=[Security(get_current_user, scopes=["write:items"])])
async def create_item(...):
    ...
```

Embed scopes in the token at issue time: `payload["scopes"] = ["read:items", "write:items"]`.
Do not derive permissions from the DB on every request — the token is the authority for its
lifetime.

---

## Debugging Async Data & Auth

| Symptom | Cause | Fix |
|---------|-------|-----|
| `MissingGreenlet: greenlet_spawn has not been called` | Accessing a lazy-loaded relationship or expired attribute inside an async function | `expire_on_commit=False`; eager-load with `selectinload()` or `joinedload()` |
| `TimeoutError: QueuePool limit of size N overflow N reached` | Pool exhausted — connections acquired faster than released | Increase `pool_size`/`max_overflow`; find unreleased sessions (missing `close()` in non-generator dependencies) |
| Stale connection errors after DB restart | Long-idle connection went dead; driver not notified | `pool_pre_ping=True`; check for `asyncpg.exceptions.ConnectionDoesNotExistError` in logs |
| `DecodeError: It is required that you pass in a value for the "algorithms" argument` | `jwt.decode()` called without `algorithms=` | Always pass `algorithms=[ALGORITHM]` — mandatory in PyJWT ≥ 2.0 |
| JWT with `{"alg":"none"}` is accepted | Old version of `python-jose` or missing algorithm restriction | Use PyJWT; never allow `"none"` in the algorithms list; always specify `algorithms=["HS256"]` |
| 401 on every request despite correct credentials | `exp` set in local time instead of UTC | Use `datetime.now(tz=timezone.utc)` — JWT timestamps are UTC by specification |
| Token validates but user lookup fails (401) | `sub` claim empty or points to a deleted user | Check `payload.get("sub")` before DB lookup; treat `None` or missing `sub` as invalid |

> **War story.** A staging API I reviewed was silently accepting tokens with `{"alg":"none","typ":"JWT"}` — no signature required. The `python-jose` version in `requirements.txt` predated the algorithm validation fix. A developer had generated a no-expiry token from jwt.io's "none" option for manual testing and committed it as a test fixture. Nobody noticed it was flowing through the production decode path in integration tests. The production API accepted it for months. The fix took two minutes: replace `python-jose` with `PyJWT`, pin `algorithms=["HS256"]` on every `decode()` call. The lesson: your test tokens expose your real validation assumptions. If a test token with no signature passes, so does an attacker's.

---

## Checkpoint

You're ready for the challenge when you can, without looking anything up:

1. Write `get_db` as an `async def` generator that yields a session, commits on success, and rolls back on exception.
2. Explain exactly why `expire_on_commit=False` is required in async SQLAlchemy and what exception you get without it.
3. Name the three pool parameters that prevent `QueuePool limit` errors and what each controls.
4. Name the two PyJWT exceptions you must catch separately when decoding, and the HTTP status code each maps to.
5. Explain the `alg:none` vulnerability in one sentence and the one-line fix.
6. Write `create_access_token` from memory with correct UTC timestamps and the three RFC 7519 claims.
7. Describe what security scopes buy you over a `is_admin: bool` field on the User model.

➡ **Challenge 04 — Async Auth** tests exactly these skills. Run `setup.sh` to get the skeleton.
