# Solution — JWT OAuth2: Bearer or 401

Four TODOs in `main.py`, each maps to one concept.

```python
from datetime import datetime, timedelta, timezone
from typing import Annotated

import jwt
from fastapi import Depends, FastAPI, HTTPException, status
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from pydantic import BaseModel

SECRET_KEY = "dojo-super-secret-do-not-ship"
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 30

_USERS = {
    "alice": {"username": "alice", "hashed_password": "secret"},
}

app = FastAPI()
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="token")


class Token(BaseModel):
    access_token: str
    token_type: str


class User(BaseModel):
    username: str


def create_access_token(data: dict, expires_delta: timedelta | None = None) -> str:
    to_encode = data.copy()
    expire = datetime.now(timezone.utc) + (expires_delta or timedelta(minutes=15))
    to_encode["exp"] = expire
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)


def authenticate_user(username: str, password: str) -> dict | None:
    user = _USERS.get(username)
    if not user:
        return None
    if user["hashed_password"] != password:
        return None
    return user


async def get_current_user(token: Annotated[str, Depends(oauth2_scheme)]) -> User:
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        sub: str | None = payload.get("sub")
        if sub is None:
            raise credentials_exception
    except jwt.InvalidTokenError:
        raise credentials_exception
    return User(username=sub)


@app.post("/token", response_model=Token)
async def login(form_data: Annotated[OAuth2PasswordRequestForm, Depends()]):
    user = authenticate_user(form_data.username, form_data.password)
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect username or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    access_token = create_access_token(
        data={"sub": user["username"]},
        expires_delta=timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES),
    )
    return Token(access_token=access_token, token_type="bearer")


@app.get("/me", response_model=User)
async def read_me(current_user: Annotated[User, Depends(get_current_user)]):
    return current_user
```

## Why each piece matters

**`create_access_token` sets `exp` explicitly.** PyJWT checks `exp` automatically on decode and raises `ExpiredSignatureError` (a subclass of `InvalidTokenError`). Without `exp`, tokens are valid forever — a catastrophe if one leaks. The `datetime.now(timezone.utc)` form avoids the deprecation warning from PyJWT 2.x, which banned naive datetimes.

**`authenticate_user` returns `None` on either a missing user or a wrong password.** The caller must not distinguish which case failed — returning different errors for "user not found" vs "wrong password" leaks the existence of usernames (a user enumeration vulnerability). The same 401 covers both.

**`get_current_user` catches `jwt.InvalidTokenError`, not `jwt.ExpiredSignatureError` alone.** `InvalidTokenError` is the base class for all decoding failures: expired, tampered signature, wrong algorithm, malformed structure. A tight catch that only handles `ExpiredSignatureError` will propagate an unhandled 500 for a tampered token — giving the attacker a different status code that confirms the server received something JWT-shaped.

**`Depends(get_current_user)` makes auth structural.** Every route that declares `current_user: Annotated[User, Depends(get_current_user)]` requires a valid token or it 401s before your code runs. This is not a guard you can forget to call — it is a type annotation on the parameter. Adding a new route without auth becomes *obviously wrong* in the function signature.

## Attacker's view

The main attack surface here is the `SECRET_KEY`. If an attacker learns it, they can mint arbitrary tokens for any username, set `exp` far in the future, and bypass all auth. Hardcoding the secret in source is fine for this lab. In production: load from `$SECRET_KEY` env var, rotate via key IDs (`kid` header claim), and treat any secret that ever hit version control as permanently compromised.

## Hardening preview

Production improvements in order of impact:

1. Use a real password hash (`passlib` + bcrypt). Plain-string comparison is only acceptable in a lab.
2. Load `SECRET_KEY` from the environment, not source: `SECRET_KEY = os.environ["JWT_SECRET"]`.
3. Set a short `exp` (15 minutes) and issue a refresh token separately — reducing the blast radius of a leaked access token.
4. Add `jti` (JWT ID) and keep a server-side deny-list for immediate revocation; otherwise logout is impossible without key rotation.
