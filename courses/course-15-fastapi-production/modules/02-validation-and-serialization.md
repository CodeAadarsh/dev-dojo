# Validation & Serialization with Pydantic v2

> **Module 02 · Course 15** — Pydantic v2 is a complete rewrite. The public API looks familiar but the semantics are stricter and several v1 patterns silently break or silently do the wrong thing. This module is the field guide to what changed and how to use it right the first time.

---

## Pydantic v2 — What Actually Changed

The headline: v2 is implemented in Rust via `pydantic-core`. Validation is 5–50× faster than v1. But the behaviour changes matter more than the speed:

**Strict vs lax coercion.** v1 was permissive — `"123"` was silently coerced to `int`. v2 defaults to `lax` mode (mostly compatible) but the coercion rules changed in ways that bite you with booleans, dates, and union types.

**`model_config` replaces inner `class Config`.** The v1 pattern:

```python
class Config:                    # v1
    orm_mode = True
```

is now:

```python
from pydantic import ConfigDict

class MyModel(BaseModel):
    model_config = ConfigDict(from_attributes=True)  # v2
```

**`.dict()` / `.json()` are deprecated.** Use `.model_dump()` and `.model_dump_json()`. FastAPI's serialization internals call `model_dump()` automatically, but any hand-rolled serialization still using `.dict()` silently works in v2.0–2.4 and will break later.

**Validators are class methods now.** The `@validator` decorator is replaced by `@field_validator` (field-level) and `@model_validator` (whole-model). The function signature changed:

```python
# v1 (deprecated)
@validator('end_date')
def end_after_start(cls, v, values):
    if v < values.get('start_date'):
        raise ValueError('end must be after start')
    return v

# v2 (correct)
from pydantic import field_validator, model_validator

@field_validator('end_date', mode='after')
@classmethod
def end_after_start(cls, v, info):
    if v <= info.data.get('start_date'):
        raise ValueError('end_date must be after start_date')
    return v
```

The `info` object replaces `values` — access sibling fields as `info.data`. Fields in `info.data` are only those that validated *before* `end_date` in the field declaration order. **Declare `start_date` before `end_date`** in the model or `info.data` won't contain it.

---

## Field Constraints and Validators

### Annotated constraints with `Field()`

```python
from pydantic import BaseModel, Field
from typing import Annotated

class OrderLine(BaseModel):
    product_id: int
    quantity: int = Field(ge=1, le=1000)
    unit_price: float = Field(gt=0)
    discount_pct: float = Field(ge=0, lt=100, default=0.0)
    notes: str | None = Field(default=None, max_length=500)
```

`ge` / `gt` / `le` / `lt` are numeric bounds. `min_length` / `max_length` apply to `str` and `list`. `pattern` takes a regex. These constraints are enforced at validation time *and* reflected in the OpenAPI schema — clients get the spec for free.

**`Annotated` is the modern idiomatic style** for reusable constraints:

```python
PositivePrice = Annotated[float, Field(gt=0)]
ShortText      = Annotated[str,   Field(max_length=200)]

class Product(BaseModel):
    name: ShortText
    price: PositivePrice
```

### `@field_validator` — single-field post-processing

```python
from pydantic import field_validator


class UserCreate(BaseModel):
    email: str
    username: str

    @field_validator('email')
    @classmethod
    def email_lowercase(cls, v: str) -> str:
        return v.lower().strip()

    @field_validator('username')
    @classmethod
    def username_no_spaces(cls, v: str) -> str:
        if ' ' in v:
            raise ValueError('username must not contain spaces')
        return v
```

`mode='before'` runs the validator before Pydantic's type coercion (receives raw input). `mode='after'` (default) runs after coercion (receives the typed value). Use `before` when you need to normalise the input format before type validation.

### `@model_validator` — cross-field validation

```python
from pydantic import model_validator


class DateRange(BaseModel):
    start: date
    end: date

    @model_validator(mode='after')
    def check_range(self) -> 'DateRange':
        if self.end <= self.start:
            raise ValueError('end must be strictly after start')
        return self
```

`mode='after'` receives the fully constructed model instance — all fields are already validated and typed. Use this for invariants that span multiple fields.

---

## `response_model` + `response_model_exclude`

```python
class UserInternal(BaseModel):
    id: int
    email: str
    password_hash: str      # never send this
    created_at: datetime


class UserPublic(BaseModel):
    id: int
    email: str
    created_at: datetime


# Option A: separate response model (preferred — explicit contract)
@app.get("/users/{uid}", response_model=UserPublic)
async def get_user(uid: int) -> UserInternal:
    return db_get_user(uid)   # returns UserInternal; FastAPI filters to UserPublic


# Option B: exclude specific fields from the source model
@app.get("/users/{uid}", response_model=UserInternal, response_model_exclude={"password_hash"})
async def get_user(uid: int) -> UserInternal:
    return db_get_user(uid)
```

Option A is almost always better: the response schema in OpenAPI reflects `UserPublic`, so the contract is clear. Option B produces an OpenAPI schema that still includes `password_hash` as optional, which is misleading.

`response_model_exclude_unset=True` is useful for PATCH endpoints: fields the client didn't touch don't appear in the response, which makes the patch semantics visible:

```python
@app.patch("/users/{uid}", response_model=UserPublic, response_model_exclude_unset=True)
async def patch_user(uid: int, patch: UserPatch) -> UserPublic:
    updated = db_patch_user(uid, patch.model_dump(exclude_unset=True))
    return updated
```

---

## Nested Models

Pydantic v2 handles arbitrary nesting:

```python
class Address(BaseModel):
    street: str
    city: str
    pincode: str = Field(pattern=r'^\d{6}$')


class Company(BaseModel):
    name: str
    registered_address: Address
    branches: list[Address] = []


class Invoice(BaseModel):
    number: str
    vendor: Company
    line_items: list[OrderLine]
    total: float
```

FastAPI serializes the whole graph. Validation errors for nested fields report their location as a tuple: `("body", "vendor", "registered_address", "pincode")`.

**Discriminated unions** — when a field can be one of several model types:

```python
from typing import Literal
from pydantic import BaseModel


class EmailNotification(BaseModel):
    kind: Literal["email"]
    to: str
    subject: str


class SlackNotification(BaseModel):
    kind: Literal["slack"]
    channel: str
    text: str


Notification = EmailNotification | SlackNotification


class AlertConfig(BaseModel):
    notification: Annotated[Notification, Field(discriminator='kind')]
```

The `discriminator='kind'` tells Pydantic to look at `notification.kind` first and route to the correct model — much faster than trying both and picking the first that validates.

---

## Custom Exception Handlers & the Error Envelope

FastAPI's default 422 body is fine for development but production APIs need a contract:

```json
{
  "status": 422,
  "error": "Validation Failed",
  "details": [
    {"field": "body.price", "message": "Input should be greater than 0"}
  ]
}
```

Override the default handler:

```python
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

app = FastAPI()


@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
    return JSONResponse(
        status_code=422,
        content={
            "status": 422,
            "error": "Validation Failed",
            "details": [
                {"field": ".".join(str(loc) for loc in e["loc"]), "message": e["msg"]}
                for e in exc.errors()
            ],
        },
    )
```

Register a catch-all for unhandled exceptions:

```python
from fastapi import HTTPException


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status_code,
        content={"status": exc.status_code, "error": exc.detail},
    )


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    # Log here — do not expose exc details to the caller
    import logging
    logging.exception("unhandled error on %s %s", request.method, request.url.path)
    return JSONResponse(
        status_code=500,
        content={"status": 500, "error": "Internal Server Error"},
    )
```

The envelope contract (`status`, `error`, always present) lets clients parse errors uniformly without branching on Content-Type or error shape.

---

## ORM Mode / `from_attributes`

SQLAlchemy (and most Python ORMs) returns objects with attributes, not dicts. Without ORM mode, `UserPublic.model_validate(orm_user)` raises a `ValidationError` because Pydantic tries to treat the object as a dict.

```python
# models.py (SQLAlchemy ORM)
class UserORM(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str]
    created_at: Mapped[datetime]


# schemas.py (Pydantic)
from pydantic import BaseModel, ConfigDict


class UserPublic(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    email: str
    created_at: datetime
```

With `from_attributes=True`, Pydantic reads attributes off the object (`user.id`, `user.email`) instead of looking for keys in a dict. Then:

```python
orm_user = session.get(UserORM, user_id)
return UserPublic.model_validate(orm_user)   # works
```

**Lazy-loaded relationships are a trap.** If `UserORM.orders` is a SQLAlchemy lazy relationship and `UserPublic` includes an `orders` field, `model_validate` will trigger a lazy load — which requires an active session. Outside a request scope this raises `MissingGreenlet`. The fix: either eager-load the relationship in the query, or exclude it from the response model.

---

## Debugging Validation & Serialization

| Symptom | Cause | Fix |
|---------|-------|-----|
| Field silently missing from response | `response_model` set but field not declared on the response schema | Add the field to the response model, or check you're using the right model class |
| `ValidationError: from_attributes` not set | ORM object passed to `model_validate()` without `ConfigDict(from_attributes=True)` | Add `model_config = ConfigDict(from_attributes=True)` to the Pydantic schema |
| `@field_validator` doesn't see a sibling field in `info.data` | Sibling field declared *after* the validated field | Reorder fields: place `start_date` before `end_date`, or use `@model_validator(mode='after')` |
| `422` on a correct payload — `loc: ["body"]` | JSON body not being parsed — wrong `Content-Type` header or body not set | Confirm the client sends `Content-Type: application/json`; for `TestClient`, pass `json={}` not `data={}` |
| Response contains `password_hash` despite `response_model_exclude` | `response_model_exclude` doesn't strip nested fields; or the return type bypasses `response_model` | Only the top-level model is filtered; use a dedicated response model without the sensitive fields |
| `model_dump()` returns all fields when you expected only set ones | Called without `exclude_unset=True` | Use `model.model_dump(exclude_unset=True)` for PATCH logic |
| v1 `@validator` decorator raises `PydanticUserError` | `@validator` is removed in v2 strict mode | Migrate to `@field_validator` with `@classmethod`; update `values` → `info.data` |

### Diagnosing a silent field drop

The most insidious case: your endpoint returns data and the client gets a 200, but one field is always missing. The model serializes successfully but strips the field.

```python
# Reproduce in a test:
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)

def test_response_shape():
    r = client.get("/users/1")
    assert r.status_code == 200
    data = r.json()
    assert "created_at" in data, (
        f"'created_at' missing from response. Got keys: {list(data.keys())}\n"
        "Check response_model declaration on the endpoint."
    )
```

Asserting on the full key set in tests catches field drops the moment they're introduced.

> **War story.** A team I worked with had an `OrderResponse` model in production for three months before they noticed that `total_amount` was being stripped. The cause: a `response_model_exclude={"total_amount"}` that was added to "temporarily hide it during a refactor" and committed with a TODO that never shipped. No test asserted the field's presence. The field was in the OpenAPI spec (because `response_model_exclude` doesn't affect the schema), so the client generated a type that expected the field — and the field was always `undefined` at runtime. One assertion in tests would have caught this on day one.

---

## Checkpoint

You're ready for the challenge when you can, without looking anything up:

1. Convert a v1 `@validator` to a v2 `@field_validator`, including the `@classmethod` decorator and `info` argument.
2. Write a cross-field validator that rejects a model where `end_date <= start_date`.
3. Explain why a field declared after the validated field is missing from `info.data`.
4. Set up `from_attributes=True` on a Pydantic model and explain when a lazy ORM relationship will blow up.
5. Register a `RequestValidationError` handler and produce a consistent error envelope.
6. Describe the difference in OpenAPI output between `response_model_exclude` and a separate response model class.
7. Name two places where silent field drops happen and how tests catch them.

➡ Next up: the **Pydantic v2 Validator** challenge — you'll add validators, ORM mode, and a custom error envelope to a half-working booking API.
