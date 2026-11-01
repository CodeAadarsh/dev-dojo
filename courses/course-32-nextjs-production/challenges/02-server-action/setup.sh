#!/usr/bin/env bash
# Plants the "Server Action: Validated Form Submission" starter project.
# Idempotent — re-running overwrites sources but does not delete node_modules.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/02-server-action"
mkdir -p "$WORK/actions"
mkdir -p "$WORK/test"

# ── package.json ──────────────────────────────────────────────────────────────
cat > "$WORK/package.json" << 'EOF'
{
  "name": "02-server-action",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "node --import tsx/esm --test 'test/*.test.mts'"
  },
  "devDependencies": {
    "@types/node": "22.10.1",
    "tsx": "4.19.1",
    "typescript": "5.7.2"
  }
}
EOF

# ── tsconfig.json ─────────────────────────────────────────────────────────────
cat > "$WORK/tsconfig.json" << 'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "skipLibCheck": true
  }
}
EOF

# ── actions/contact.ts skeleton ───────────────────────────────────────────────
cat > "$WORK/actions/contact.ts" << 'EOF'
'use server'
// actions/contact.ts
// Implement submitContact so it validates input and returns ActionResult<Contact>.
//
// Rules:
//   • name  — must be a non-empty string (trim before check)
//   • email — must contain '@' and not be empty
//   • On success : return { ok: true,  data: Contact }
//   • On failure : return { ok: false, error: '<reason>' }  — do NOT throw
//
// Hints:
//   • id        → crypto.randomUUID()   (Node 18+ global, no import needed)
//   • createdAt → new Date().toISOString()

export type Contact = {
  id: string
  name: string
  email: string
  createdAt: string
}

export type ActionResult<T> =
  | { ok: true; data: T }
  | { ok: false; error: string }

export async function submitContact(input: {
  name: string
  email: string
}): Promise<ActionResult<Contact>> {
  // TODO: validate input.name and input.email
  // TODO: on success, build and return a Contact object
  // TODO: on failure, return { ok: false, error: '<reason>' }
  throw new Error('not implemented')
}
EOF

# ── test/sample.test.mts (visible — shows the call pattern) ───────────────────
cat > "$WORK/test/sample.test.mts" << 'EOF'
// sample.test.mts — visible example showing how the harness imports + calls the action.
// The real harness (run by verify.sh) tests more cases. Make this green first.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { submitContact } from '../actions/contact.ts'

test('sample — valid input resolves and returns ok=true', async () => {
  const result = await submitContact({ name: 'Alice', email: 'alice@example.com' })
  assert.equal(result.ok, true, `expected ok=true, got ok=${result.ok}`)
})
EOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement submitContact in actions/contact.ts"
echo "                 so it validates input and returns ActionResult<Contact>."
echo
echo "Prerequisites  :"
echo "  cd $WORK && npm install"
echo
echo "Run sample test:"
echo "  node --import tsx/esm --test 'test/sample.test.mts'"
echo
echo "Verify + flag  :"
echo "  bash courses/course-32-nextjs-production/challenges/02-server-action/verify.sh"
