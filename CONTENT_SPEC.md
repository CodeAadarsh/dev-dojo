# KUBE-DOJO Content Authoring Spec

This is the **contract** between course content and the platform reader. The web
app (`platform/`) scans `courses/*` at request time; if a file is in the right
place with the right shape, it just works — no code changes needed to add a
course, module, or challenge.

> Authoring a new challenge? Copy an existing one under
> `courses/course-01-ops-security/challenges/` and edit. Those are the reference
> implementations: `01-make-it-survive` (verifier) and
> `02-base64-is-not-encryption` (discovery).

---

## Directory layout

```
courses/
  course-NN-slug/
    course.json                 # course metadata (required)
    modules/
      01-topic.md               # teaching guide, ordered by numeric prefix
      02-topic.md
    challenges/
      01-challenge-slug/
        challenge.json           # metadata (required)
        brief.md                 # the mission shown in the platform (required)
        setup.sh                 # plants the scenario into the kind cluster
        verify.sh                # verifier challenges only: prints flag on success
        solution.md              # full walkthrough (revealed on demand)
        hints.json               # array of progressive hint strings
        flag.sha256              # sha256 of the exact flag string (required)
```

The platform discovers modules by scanning `modules/*.md` (ordered by the
leading number in the filename; the module title is the first `#` heading).
Challenges are discovered by scanning `challenges/*/challenge.json`.

---

## `course.json`

```json
{
  "id": "course-02-sre-production",      // must equal the directory name
  "slug": "sre-production",               // URL slug, unique across courses
  "title": "Production SRE",
  "order": 2,                             // sort order on the home grid
  "status": "available",                  // "available" | "coming-soon"
  "difficulty": "Advanced",
  "tags": ["sre", "scaling", "observability"],
  "description": "One tight paragraph shown on the course card and header."
}
```

Set `status` to `"available"` once the course has at least one module AND one
challenge. Leave `"coming-soon"` while empty (the card renders dimmed).

---

## `challenge.json`

```json
{
  "slug": "01-challenge-slug",            // must equal the directory name
  "title": "Human Readable Title",
  "order": 1,                             // sort order within the course
  "difficulty": "Easy",                   // Easy | Medium | Hard | Insane
  "flagType": "verifier",                 // "verifier" | "discovery"
  "points": 25,
  "estMinutes": 25,
  "tags": ["deployments", "probes"],
  "objective": "One sentence shown under the title."
}
```

---

## Flags — the two types

Every challenge stores **only** `flag.sha256` (the hex sha256 of the flag), never
the plaintext in a committed-answer field. The platform hashes the submitted
string (trimmed) and compares.

Generate the hash with **no trailing newline**:

```bash
printf '%s' 'KUBE{your_flag_here}' | shasum -a 256 | awk '{print $1}' > flag.sha256
```

Flag format: `KUBE{lower_snake_case_tokens}`. Make the token *mean* something —
it should read like the lesson (`KUBE{base64_is_not_encryption}`).

### `flagType: "verifier"`
- Ship a **`verify.sh`** that inspects live cluster state and, only when every
  check passes, prints the flag (plaintext is fine — this is a solo lab; the
  solution reveals it anyway).
- `verify.sh` must use `set -uo pipefail`, a `fail()` helper that `exit 1`s with
  a specific message, and rely only on `kubectl` + POSIX tools (**no `jq`** — not
  guaranteed installed; use `-o jsonpath`).
- The platform shows a "run the verifier" step for these.

### `flagType: "discovery"`
- The flag is *embedded in the cluster* by `setup.sh` (in a Secret, annotation,
  configmap, etcd, a log line, etc.). The learner extracts it directly.
- No `verify.sh` needed. The brief should hint at 2–3 legitimate extraction paths.

---

## `setup.sh` conventions

- Start with `set -euo pipefail` and a shebang `#!/usr/bin/env bash`.
- Warn (don't fail) if `kubectl config current-context` isn't `kind-dojo`.
- Create a dedicated namespace per challenge: `dojo-<short-topic>`.
- Be **idempotent** — use `kubectl apply` and `--dry-run=client -o yaml | kubectl apply -f -`
  for namespaces/secrets so re-running is safe.
- End by echoing what was planted and what to do next.
- Scripts are invoked by the learner from the **kube-dojo workspace root** as
  `bash courses/<course>/challenges/<slug>/setup.sh`.

---

## `brief.md` conventions

- Lead with a short real-world framing (an incident, a code review, a ticket).
- State the **mission / target state** explicitly and unambiguously — for
  verifier challenges, list the exact conditions `verify.sh` checks.
- Teach *why it matters*, not just the steps (steps live in the solution).
- Markdown only (rendered by react-markdown): headings, tables, fenced code,
  lists, blockquotes. Braces like `KUBE{...}` and `{{ }}` render literally.

## `solution.md` conventions

- Give the complete, copy-pasteable answer (YAML, commands).
- Explain *why each piece* is correct, not just what to type.
- Where relevant, add the **attacker's view** or a **hardening preview** to keep
  the balanced ops+security framing.

## `hints.json`

A JSON array of 2–3 strings, ordered least→most revealing. Progressive: the last
hint may name the exact command/field but still not hand over the whole answer.

---

## Difficulty & pitch

Audience: an SDE who already runs Kubernetes at work (intermediate→advanced).
Skip "what is a pod." Go deep on the parts that separate competent from expert.
Intermediate = Easy/Medium; advanced edge-cases = Hard; adversarial/multi-step = Insane.

## Hard rules

- Full, runnable content. **No `// TODO`, no stubs, no placeholder flags.**
- Every challenge dir MUST contain: `challenge.json`, `brief.md`, `flag.sha256`.
- Verifier challenges MUST also contain `verify.sh`; both types SHOULD contain
  `setup.sh`, `solution.md`, `hints.json`.
- Namespaces are `dojo-*` so `kubectl get ns | grep dojo-` lists all lab state.
- Pin images to tags (e.g. `nginx:1.27-alpine`), never `:latest`.
