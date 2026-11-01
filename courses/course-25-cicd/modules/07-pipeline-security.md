# Pipeline & Supply-Chain Security

> **Module 07 · Course 25** — Your pipeline has `contents:write`, can push to production, and runs arbitrary code on every pull request. That is not a CI system; it is a privileged server that anyone with a PR can execute commands on. This module is about treating the pipeline as an attack surface from the start, not as an afterthought once an incident teaches you to.

You have shipped things with GitHub Actions. This module covers the specific ways pipelines get compromised — and the concrete controls that prevent each one. The threat model is real: supply-chain attacks on CI pipelines (SolarWinds, XZ Utils, `tj-actions/changed-files`) now regularly make national news.

---

## The Pipeline as an Attack Surface

A CI job is code execution. The attacker's goal is to reach that execution path, whether through a compromised third-party action, a malicious PR, a leaked token, or a poisoned dependency.

```
┌─────────────────────────────────────────────────────────────────┐
│  GitHub Actions runner (ubuntu-latest VM)                       │
│                                                                 │
│  ├── checkout: third-party action code runs here                │
│  ├── environment: GITHUB_TOKEN, AWS_SECRET_ACCESS_KEY in env    │
│  ├── network: unrestricted outbound by default                  │
│  └── artifacts: builds + signs + pushes your production image   │
│                                                                 │
│  Attack surfaces:                                               │
│  ① Third-party action with a malicious update                   │
│  ② PR-triggered workflow that exfiltrates secrets               │
│  ③ Over-privileged GITHUB_TOKEN used to push to main            │
│  ④ Hardcoded AWS/GCP credentials in env or logs                 │
└─────────────────────────────────────────────────────────────────┘
```

Each of these has a direct mitigation. None require buying anything.

---

## Pinned Actions (by SHA, not by tag)

A mutable tag (`uses: actions/checkout@v4`) is a moving target. The action owner can push a new commit to the `v4` tag at any time. The `tj-actions/changed-files` incident (March 2024) did exactly this: attackers pushed a tag update that dumped `ACTIONS_RUNTIME_TOKEN` values from every workflow that ran.

Pin to the commit SHA instead:

```yaml
# Vulnerable — tag can be moved to a malicious commit
- uses: actions/checkout@v4

# Safe — SHA is immutable
- uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
```

How to find the SHA for a known tag:

```bash
# GitHub CLI
gh api repos/actions/checkout/git/ref/tags/v4.2.2 --jq '.object.sha'

# Or: browse github.com/actions/checkout/releases/tag/v4.2.2
# and copy the "Full SHA" from the tag commit
```

Add the tag as a comment so humans can read the version:

```yaml
- uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
- uses: docker/build-push-action@4f58ea79222b3b9dc2c8bbdd6debcef730109a75  # v6.9.0
```

**Automate this with Dependabot.** A single entry in `.github/dependabot.yml` keeps SHA pins up-to-date:

```yaml
version: 2
updates:
- package-ecosystem: "github-actions"
  directory: "/"
  schedule:
    interval: "weekly"
  groups:
    github-actions:
      patterns: ["*"]
```

Dependabot opens PRs that update SHA pins to the latest release SHA — you get the security fix without a supply-chain surprise.

---

## Least-Privilege Tokens (GITHUB_TOKEN Scopes)

`GITHUB_TOKEN` is a short-lived credential GitHub injects into every workflow run. By default it has more permissions than most jobs need.

Declare permissions explicitly at the workflow or job level. Start from nothing and add what you actually use:

```yaml
# Workflow-level default — deny everything
permissions: {}

jobs:
  build:
    # This job only needs to read code and write packages
    permissions:
      contents: read
      packages: write    # push to GHCR
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
    - run: docker build -t ghcr.io/org/app:${{ github.sha }} .
    - run: docker push ghcr.io/org/app:${{ github.sha }}

  release:
    permissions:
      contents: write    # create GitHub release
      id-token: write    # OIDC — see next section
    runs-on: ubuntu-latest
```

Common scope reference:

| Scope | Use | Danger if over-granted |
|-------|-----|----------------------|
| `contents: write` | Push commits, create releases | Attacker can push to `main`, modify release assets |
| `packages: write` | Push to GHCR | Attacker can overwrite your production image |
| `id-token: write` | OIDC token generation | Required for keyless signing and cloud auth |
| `pull-requests: write` | Comment on PRs, approve | Attacker can approve their own malicious PR |
| `actions: write` | Cancel/re-run workflows | Attacker can abort security scans |

Set `permissions: {}` at the workflow level as a default, then grant the minimum per-job. A job with no `permissions:` key inherits the workflow default.

---

## OIDC Instead of Static Credentials

Static credentials (`AWS_SECRET_ACCESS_KEY`, `GCP_SERVICE_ACCOUNT_KEY`) stored in GitHub Secrets are long-lived secrets that never expire. They appear in leak reports, get accidentally logged, and require manual rotation.

OIDC replaces them with short-lived, automatically-rotated tokens. GitHub generates a signed JWT that cloud providers (AWS, GCP, Azure) verify directly:

```
GitHub Actions runner
  → requests OIDC token from GitHub's token endpoint
    → GitHub signs JWT: {sub: "repo:org/app:ref:refs/heads/main", aud: "sts.amazonaws.com", ...}
      → runner presents JWT to AWS STS AssumeRoleWithWebIdentity
        → AWS verifies JWT signature against GitHub's public JWKS endpoint
          → AWS returns short-lived IAM credentials (15 min default)
```

The workflow needs `id-token: write` to request the JWT, then nothing else changes:

```yaml
jobs:
  deploy:
    permissions:
      id-token: write
      contents: read
    runs-on: ubuntu-latest
    steps:
    - uses: aws-actions/configure-aws-credentials@e3dd6a429d7300a6a4c196c26e071d42e0343502  # v4.0.2
      with:
        role-to-assume: arn:aws:iam::123456789:role/github-actions-deploy
        aws-region: us-east-1
    - run: aws ecr get-login-password | docker login ...
```

The IAM role's trust policy restricts which GitHub repos and branches can assume it:

```json
{
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:sub":
        "repo:org/app:ref:refs/heads/main"
    }
  }
}
```

Only pushes to `main` in `org/app` can assume this role. A fork or a feature branch cannot.

---

## Secret Scanning

GitHub's built-in secret scanning detects known credential patterns (AWS keys, GCP service accounts, Stripe keys, GitHub tokens) in push commits and alerts you — but only for public repos by default. For private repos, enable it under **Settings → Security → Secret scanning**.

**Push protection** blocks a push that contains a known secret before it reaches the repo. Enable it:

```
Settings → Code security → Secret scanning → Push protection: Enable
```

For custom patterns (internal API keys, SAP service credentials), add them under **Settings → Security → Secret scanning → Custom patterns**.

**In CI**, add `gitleaks` or `trufflehog` as a pipeline step to catch secrets before push protection sees them:

```yaml
- name: Scan for secrets
  uses: gitleaks/gitleaks-action@44c470f53a4a5c8b4f4e7d9a8d8e6e2c1b3d5a79  # v2.3.2
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

A secret found in a committed file is already a breach. The pipeline scan catches it before the commit reaches the remote; push protection is a second line of defence.

---

## Protecting Release Branches

Branch protection rules are the access-control layer for your deployment trigger. Configure them under **Settings → Branches → Branch protection rules** for `main`:

```
Required settings for main:
  ✓ Require a pull request before merging
  ✓ Require N approvals (N ≥ 1 for personal, N ≥ 2 for regulated)
  ✓ Dismiss stale reviews when new commits are pushed
  ✓ Require status checks to pass (build, test, security scan)
  ✓ Require branches to be up to date before merging
  ✓ Require signed commits (if your team has GPG set up)
  ✓ Do not allow bypasses (even admins go through PRs)
  ✓ Restrict who can push to matching branches
```

**The deployment-branch pattern.** Never deploy directly from `main`. Use a protected `release` branch or GitHub Environments with required reviewers:

```yaml
jobs:
  deploy-prod:
    environment:
      name: production
      url: https://app.example.com
    # GitHub pauses the job here until a designated reviewer approves it
```

Environment protection rules let you require a specific person to approve the production deploy, creating an auditable approval gate that is enforced by the platform rather than by convention.

---

## SLSA Levels

SLSA (Supply-chain Levels for Software Artifacts) is a framework for describing how trustworthy your build provenance is. Think of it as a maturity model for "how hard is it to tamper with what you shipped?"

| Level | Key requirement | What it prevents |
|-------|----------------|-----------------|
| SLSA 1 | Provenance exists (build logs, metadata) | No-provenance confusion — you can at least trace what was built |
| SLSA 2 | Provenance is signed by the build service | Tampered provenance — an attacker cannot forge build metadata |
| SLSA 3 | Build runs on a hardened, isolated runner; source is two-person reviewed | Compromised build environment — even a malicious maintainer cannot inject |
| SLSA 4 | Two-party review, hermetic reproducible builds | Reproducibility attacks — anyone can rebuild and verify the artifact matches |

Most teams target SLSA 2. GitHub Actions + `slsa-framework/slsa-github-generator` generates SLSA 2/3 provenance automatically:

```yaml
jobs:
  build:
    permissions:
      id-token: write
      contents: read
      packages: write
    outputs:
      digest: ${{ steps.build.outputs.digest }}
    steps:
    - uses: docker/build-push-action@4f58ea79222b3b9dc2c8bbdd6debcef730109a75  # v6.9.0
      id: build
      with:
        push: true
        tags: ghcr.io/org/app:${{ github.sha }}

  provenance:
    needs: build
    uses: slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@v2.0.0
    with:
      image: ghcr.io/org/app
      digest: ${{ needs.build.outputs.digest }}
    permissions:
      id-token: write
      packages: write
```

The provenance attestation is stored in the registry alongside the image. Verify it before deploying:

```bash
cosign verify-attestation \
  --type slsaprovenance \
  --certificate-identity-regexp="https://github.com/slsa-framework/slsa-github-generator" \
  ghcr.io/org/app@sha256:<digest>
```

---

## Dependency Review

Dependency vulnerabilities are a supply-chain risk at the code level. GitHub's dependency review action blocks PRs that introduce a package with a known CVE:

```yaml
- name: Dependency review
  uses: actions/dependency-review-action@3b139cfc5fae8b618d3eae3675e383bb1769c019  # v4.5.0
  with:
    fail-on-severity: high
    deny-licenses: GPL-3.0, AGPL-3.0   # block copyleft in commercial code
```

Run this in a `pull_request` trigger workflow so it blocks the merge rather than the deploy. A vulnerability found at merge time is far cheaper to fix than one found after a CVE advisory on a deployed image.

---

## Debugging Pipeline Security

Security misconfigurations fail in two modes: noisily (the pipeline errors with `403 Forbidden`) and silently (the pipeline succeeds but an attacker already has what they needed). Both matter.

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `Error: HttpError: Resource not accessible by integration` on a workflow step that writes | `GITHUB_TOKEN` missing the required scope for that operation | Add the specific permission at the job level (`contents: write`, `packages: write`); never increase to `write-all` |
| Pipeline passes but a secret value appears in the workflow run log | `echo $SECRET` or `run: command ${{ secrets.FOO }}` — GitHub masks known secrets but expression expansion happens before masking | Never expand secrets directly in `run:`; pass via `env:` where GitHub masks them; audit with `grep -r 'secrets\.' .github/workflows/` |
| Third-party action starts behaving unexpectedly after an unrelated push | Tag-pinned action (`@v2`) was updated by the action maintainer to point to a new (possibly malicious) commit | Pin all actions to SHA immediately; check the action's release for the legitimate update; rotate any secrets the action had access to |
| OIDC authentication fails with `Error assuming role` in AWS | The IAM role's trust policy `Condition` does not match the workflow's OIDC subject (wrong repo name, branch, or environment) | Print the actual JWT subject with `aws sts get-caller-identity` debug output; adjust the trust policy condition to match exactly |
| `cosign verify` fails on the production image | Image was re-tagged (tag moved to a different digest), or the provenance was generated for the digest but verified against the tag | Always verify by digest (`@sha256:...`), never by tag; digest is immutable |
| Dependabot opens a SHA-update PR but the new SHA is not for the intended version | Dependabot resolved a SHA for a pre-release or a commit that is not a tagged release | Review Dependabot PR descriptions for the version; use `gh release list` to confirm the SHA maps to the expected tag |

> **War story.** A team using `tj-actions/changed-files@v35` woke up to an incident notice on a Monday morning — the action's `v35` tag had been moved to a malicious commit by attackers who compromised the action maintainer's account over the weekend. Every repo that ran the action on a push after the tag was moved had its `ACTIONS_RUNTIME_TOKEN` dumped to the workflow log. The token was valid for a few hours and could be used to write packages and trigger other workflows. The team's immediate response: rotate GitHub tokens, revoke and re-generate the `GHCR_TOKEN` that had been read by the action, and audit the GHCR package history for unexpected pushes. The fix: SHA-pin every action in every workflow that same morning. Total blast radius would have been zero if they had been SHA-pinned before the incident, because `@11bd71901bbe5b...` cannot be moved — the SHA refers to an immutable Git object. Every action pin in this dojo's own workflows is SHA-pinned for exactly this reason.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Explain why pinning an action to a SHA (`@abc123...`) is safer than pinning to a tag (`@v4`), and state what happened to `tj-actions/changed-files`.
2. Write the `permissions:` block for a job that needs to read code and push to GHCR — nothing else.
3. Describe the OIDC flow: what GitHub generates, what AWS verifies, and what the runner receives.
4. State what `token.actions.githubusercontent.com:sub` restricts in an AWS IAM trust policy.
5. Name the two GitHub settings you enable to prevent secrets from being pushed to the repo.
6. Describe what a GitHub Environment protection rule does and why it is stronger than a branch protection rule for deployment gating.
7. State the difference between SLSA 2 and SLSA 3 provenance in one sentence.
8. Given a workflow log that shows a secret value in plaintext, name the likely cause and the immediate fix.
9. Explain why a `cosign verify` step must verify by digest, not by tag.

➡ You have completed the core CI/CD module sequence. The challenges ahead ask you to author real pipeline config, run real gates, and wire a deploy that survives a verifier — take the concepts from this module and make them operational.
