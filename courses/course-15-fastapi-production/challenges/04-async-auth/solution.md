# Solution — Async Auth Endpoints

## Complete implementation of `main.py`

```python
from fastapi import FastAPI, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from pydantic import BaseModel
from datetime import datetime, timedelta, timezone
import jwt
from passlib.context import CryptContext

SECRET_KEY = "dojo-secret-change-in-prod"
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 30

app = FastAPI()
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/token")

_users_db: dict = {}


class UserCreate(BaseModel):
    username: str
    email: str
    password: str


class UserOut(BaseModel):
    username: str
    email: str


class Token(BaseModel):
    access_token: str
    token_type: str


@app.post("/auth/register", status_code=201, response_model=UserOut)
def register(user: UserCreate):
    if user.username in _users_db:
        raise HTTPException(status_code=409, detail="Username already registered")
    _users_db[user.username] = {
        "hashed_password": pwd_context.hash(user.password),
        "email": user.email,
    }
    return UserOut(username=user.username, email=user.email)


@app.post("/auth/token", response_model=Token)
def login(form: OAuth2PasswordRequestForm = Depends()):
    user = _users_db.get(form.username)
    if not user or not pwd_context.verify(form.password, user["hashed_password"]):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect username or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    now = datetime.now(tz=timezone.utc)
    payload = {
        "sub": form.username,
        "iat": now,
        "exp": now + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES),
    }
    token = jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)
    return Token(access_token=token, token_type="bearer")


@app.get("/users/me", response_model=UserOut)
def get_current_user(token: str = Depends(oauth2_scheme)):
    credentials_exc = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
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

    user = _users_db.get(username)
    if not user:
        raise credentials_exc
    return UserOut(username=username, email=user["email"])
```

## Why each piece matters

**`409` on duplicate registration** — returning `400` here is a common mistake. `409 Conflict`
is the semantically correct code: the request was well-formed but conflicts with existing state.
Clients can distinguish "bad request" (fix your payload) from "conflict" (retry with different
data).

**`pwd_context.hash()` + `pwd_context.verify()`** — passlib's bcrypt context generates a random
salt on every `hash()` call. Two calls with the same password produce different hashes. This is
correct. `verify()` extracts the salt from the stored hash automatically — you never need to
manage salts manually.

**`algorithms=[ALGORITHM]`** — PyJWT >= 2.0 requires the algorithms list to be explicit. Without
it, older versions would accept `{"alg":"none"}` tokens with no signature. Always pass the list.

**`jwt.ExpiredSignatureError` vs `jwt.InvalidTokenError`** — catch them separately because they
warrant different error messages. An expired token might indicate a session timeout (the user
should re-login); an invalid token indicates a corrupt or forged token (do not hint at why).

**`WWW-Authenticate: Bearer` header** — required by RFC 6750. Some clients (like curl) use it
to surface auth errors correctly. FastAPI's `oauth2_scheme` expects this header on 401 responses.

## Security hardening preview

In production, `SECRET_KEY` comes from an env var and is at least 32 random bytes:

```python
import os
SECRET_KEY = os.environ["JWT_SECRET_KEY"]  # never commit this value
```

Token expiry should be short (15–30 minutes) for access tokens. Use refresh tokens for
long-lived sessions. The challenge uses 30 minutes for simplicity; many production APIs use 5–15.
