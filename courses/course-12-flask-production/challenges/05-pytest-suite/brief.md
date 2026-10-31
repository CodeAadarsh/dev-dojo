# Test the App You Didn't Write

A colleague pushed `app.py` without a test file, tagged the PR "ready for review", and left for the day. The endpoint contracts are documented only in the code itself. Your job: write the tests, not the app.

This is the real day-to-day skill — reading an existing implementation, identifying the observable contract at each endpoint, and encoding that contract as reproducible assertions. The verifier checks that your test functions exist *and* pass.

## Target state

Your `tests/test_app.py` must contain **all six of these named functions** and every one must pass when `pytest` runs:

| Required test function | What it must assert |
|---|---|
| `test_health_returns_200` | `GET /health` → `200` |
| `test_health_body` | `GET /health` body contains `{"status": "ok"}` |
| `test_create_task_returns_201` | `POST /tasks` with a valid body → `201` |
| `test_create_task_has_id` | Created task response body contains an `id` field |
| `test_get_task_returns_200` | `GET /tasks/<id>` for an existing task → `200` |
| `test_get_missing_task_returns_404` | `GET /tasks/999999` → `404` |

The verifier will `grep` for the exact function names before running pytest. A function that exists but raises `AssertionError` is still a failure.

## Working directory

```
$HOME/.kube-dojo-work/05-pytest-suite/
  app.py              ← the app — read it, do not edit it
  requirements.txt
  tests/
    test_app.py       ← write your tests here (skeleton provided)
```

## Rules

- Use Flask's `app.test_client()` — the skeleton shows the fixture pattern.
- Do not modify `app.py`.
- Function names must match the table exactly — the verifier greps for them.
- Run the verifier from the repo root: `bash courses/course-12-flask-production/challenges/05-pytest-suite/verify.sh`

> Testing code you didn't write forces you to reason about the contract from the outside — the same perspective your callers have. If you can't describe what each endpoint must return without looking at the implementation, you don't know it well enough to ship it.
