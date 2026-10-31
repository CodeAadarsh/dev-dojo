# Test Doubles with dependency_overrides

A new teammate pushed a FastAPI service with a notification dependency that fires real SMTP
emails when called. The test suite exists but every test crashes immediately with:

```
RuntimeError: real EmailNotifier called in tests — use a test double
```

The app code is correct and must not be changed. Your job is to implement the fixtures in
`tests/conftest.py` so the three test functions in `tests/test_app.py` all pass.

## Context

`setup.sh` plants the following in your work directory:

```
~/.kube-dojo-work/05-test-doubles/
├── main.py               # complete FastAPI app — do not edit
└── tests/
    ├── conftest.py       # fixtures — this is the file you edit
    └── test_app.py       # three tests with TODOs — implement them here too
```

`main.py` defines:
- `NotificationService` (Protocol) with `send_welcome` and `send_goodbye` methods
- `EmailNotifier` (the real implementation — raises `RuntimeError` to prevent accidental calls)
- `get_notifier()` dependency function
- `POST /users` — creates a user, calls `notifier.send_welcome(username)`
- `DELETE /users/{username}` — removes the user, calls `notifier.send_goodbye(username)`

## Prerequisites

```bash
cd ~/.kube-dojo-work/05-test-doubles
python3 -m venv .venv && . .venv/bin/activate
pip install fastapi "uvicorn[standard]" httpx pytest pydantic
```

## Mission

Edit `tests/conftest.py` to:

1. Define a `RecordingNotifier` class that implements `NotificationService` by appending
   `{"event": "welcome"|"goodbye", "username": str}` dicts to a `self.calls` list instead
   of raising.

2. Define a `recorder` pytest fixture (function scope) that yields a fresh `RecordingNotifier`.

3. Define a `client` pytest fixture (function scope) that:
   - Uses `app.dependency_overrides` to replace `get_notifier` with a function returning the
     `recorder` instance.
   - Yields a `TestClient(app)`.
   - Cleans up `app.dependency_overrides` after the test.

Then edit `tests/test_app.py` to fill in the three `assert` statements marked with `# TODO`.

The verifier checks that:
- `test_create_user_calls_welcome` passes: POST /users returns 201, recorder has a welcome event.
- `test_duplicate_user_returns_409` passes: second POST with same username returns 409.
- `test_delete_user_calls_goodbye` passes: DELETE /users/{username} returns 204, recorder has a goodbye event.

## Why it matters

`dependency_overrides` is the idiomatic FastAPI way to inject test doubles. The alternative —
`unittest.mock.patch` on the production module — is fragile: it patches a name binding, so
if the dependency is imported differently (from X import Y vs import X; X.Y) the patch misses.
`dependency_overrides` patches at the dependency-injection layer and is always correct regardless
of import style.

## Verify

```bash
bash courses/course-15-fastapi-production/challenges/05-test-doubles/verify.sh
```

All three tests green → flag printed.
