# Validate or Regret It

Your on-call rotation fires at 2 AM. The culprit: a React form submitted `{"name": "", "age": "twenty-three"}` and the API responded `500 Internal Server Error` with a raw Python traceback leaking your stack layout. Not a sec-review you want to write.

Two root causes:
1. The endpoint trusted caller data — no validation before touching it.
2. Unhandled errors fell through to Flask's default HTML error page instead of your consistent API format.

Your job: add field validation and a global 404 handler to the skeleton app so the harness passes.

## Target state

The verifier runs `tests/test_harness.py` — a pytest suite you must not edit. It passes only when:

| Check | Expected |
|-------|----------|
| `POST /users` missing `name` | `422` with `Content-Type: application/json` |
| `POST /users` missing `age` | `422` with JSON body |
| `POST /users` with `age` as a string | `422` |
| `POST /users` with `age` outside 1–120 | `422` |
| `POST /users` valid body `{"name":"Alice","age":30}` | `201` with the user object |
| `GET /does-not-exist` | `404` with `Content-Type: application/json` |
| 422 body shape | `{"status": 422, "error": "Unprocessable Entity", "details": [...]}` |
| 404 body shape | `{"status": 404, "error": "Not Found", "message": "..."}` |

## Working directory

```
$HOME/.kube-dojo-work/04-validation-and-errors/
  app.py              ← edit this
  requirements.txt
  tests/
    test_harness.py   ← DO NOT EDIT (verifier runs this)
```

## Rules

- Use the `create_app()` factory — the test harness imports it.
- No external validation libraries required; a plain `isinstance` / `in` check is fine. marshmallow or pydantic are allowed if you prefer.
- Register the 404 handler via `@app.errorhandler(404)`.
- Run the verifier from the repo root: `bash courses/course-12-flask-production/challenges/04-validation-and-errors/verify.sh`

> The error envelope shape (`status`, `error`, `details` / `message`) is the convention your whole API will reuse. Get it right once, reference it everywhere.
