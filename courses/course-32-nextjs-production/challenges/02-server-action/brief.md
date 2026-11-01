# Server Action: Validated Form Submission

Your team is migrating a contact form from a REST endpoint to a Next.js Server Action. A senior engineer left a review comment: *"The action is wired up but the body is `throw new Error('not implemented')`. Please implement validation and the result type before we ship — the client component reads `result.ok` to decide what to render."*

The tricky part is the return type: the action must return a discriminated union (`{ ok: true, data }` or `{ ok: false, error }`), never throw. Throwing in a Server Action causes Next.js to return a 500 to the client and lose the typed response — the calling component can't distinguish between "server crashed" and "user gave bad input."

Your job: implement `submitContact` in `actions/contact.ts` until the `node --test` harness goes green.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/02-server-action/
├── package.json
├── tsconfig.json
├── actions/
│   └── contact.ts    # stub: always throws
└── test/
    └── sample.test.mts  # visible test showing the import + call pattern
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/02-server-action
npm install
```

## Mission

Implement `submitContact` in `actions/contact.ts`. The `ActionResult<T>` and `Contact` types are declared — only the function body is stubbed.

The harness asserts:

| Input | Required result |
|-------|----------------|
| `{ name: 'Alice', email: 'alice@corp.io' }` | `{ ok: true, data: Contact }` where `data` has `id`, `name`, `email`, `createdAt` |
| `{ name: '', email: 'x@y.com' }` | `{ ok: false, error: <non-empty string> }` |
| `{ name: 'Bob', email: 'notanemail' }` | `{ ok: false, error: <non-empty string> }` |
| `{ name: 'Carol', email: '' }` | `{ ok: false, error: <non-empty string> }` |

Validation rules:
- `name` must be a non-empty string (after trim)
- `email` must be a non-empty string that contains `@`

On success: return `{ ok: true, data: { id, name, email, createdAt } }` where `id` is a `string` (use `crypto.randomUUID()`) and `createdAt` is an ISO 8601 string (use `new Date().toISOString()`).

On any validation failure: return `{ ok: false, error: '<reason>' }`. **Do not throw.**

The `'use server'` directive at the top of the file is cosmetic here (the test imports the module directly), but it must be present — Next.js's build uses it to decide which modules are promoted to server-only.

## Why the return type design matters

A Server Action that throws propagates as an untyped error to the client. The `ActionResult<T>` discriminated union is the idiomatic fix: the calling component does `if (result.ok) { ... } else { showError(result.error) }` — typed, exhaustive, no try/catch. This pattern also works with `useFormState` (now `useActionState` in React 19) which surfaces the action return value as component state.

## Run your implementation

```bash
cd ~/.kube-dojo-work/02-server-action
node --import tsx/esm --test 'test/sample.test.mts'
```

## Verify

```bash
bash courses/course-32-nextjs-production/challenges/02-server-action/verify.sh
```

All checks green → flag printed.
