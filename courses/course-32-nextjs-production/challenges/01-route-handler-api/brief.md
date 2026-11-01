# Route Handler: Typed API Endpoint

A code review comment lands on your PR: *"The route file is there but every handler throws 501. Tests are skipped. Please implement before merge."* The PM has also weighed in: status codes matter — a frontend team downstream reacts to `201` vs `200` vs `422` to update its optimistic UI state. Getting them wrong breaks production, silently.

Your job: implement `GET` and `POST` in `app/api/todos/route.ts` until the `node --test` harness goes green.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/01-route-handler-api/
├── package.json          # tsx + typescript, node:test runner
├── tsconfig.json
├── app/
│   └── api/
│       └── todos/
│           └── route.ts  # stub: GET and POST throw 501
└── test/
    └── sample.test.mts   # visible test showing how to import + call a handler
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/01-route-handler-api
npm install
```

## Mission

Implement the two exported functions in `app/api/todos/route.ts`. The `Todo` type, the in-memory store, and the `_reset()` helper are already declared — only the bodies are stubbed.

The harness asserts exact HTTP semantics:

| Method | Condition | Required status | Body |
|--------|-----------|-----------------|------|
| `GET`  | always    | **200** | `{ todos: Todo[] }` |
| `POST` | valid body (`title` is a non-empty string) | **201** | `{ todo: Todo }` |
| `POST` | missing or empty `title` | **422** | `{ error: string }` |

The handlers must use the Web API `Request` / `Response` only — no `next/server` import. This is intentional: the file becomes testable with plain `node --test` and is forward-compatible with any runtime that supports the Fetch API.

## Why the status codes matter

`201 Created` carries a semantic promise: a resource was born. Frontend code and HTTP caches treat it differently from `200 OK`. `422 Unprocessable Entity` is the correct signal for "I understood your JSON but the *content* is wrong" — distinct from `400 Bad Request` ("I couldn't even parse it") or `500` ("I crashed"). Using the right codes is a contract with every consumer of your API.

## Run your implementation

```bash
cd ~/.kube-dojo-work/01-route-handler-api
node --import tsx/esm --test test/sample.test.mts
```

## Verify

```bash
bash courses/course-32-nextjs-production/challenges/01-route-handler-api/verify.sh
```

All checks green → flag printed.
