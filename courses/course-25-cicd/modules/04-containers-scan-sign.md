# Containers: Build, Scan & Sign

> **Module 04 · Course 25** — Shipping a Docker image is easy. Shipping a Docker image you can trust — that is reproducible, scanned for known vulnerabilities, tied to an auditable identity, and verifiable at deploy time — is the gap between a hobbyist pipeline and a production supply chain. This module is about closing that gap. Post-SolarWinds, post-Log4Shell, "we didn't know what was in the image" is not an acceptable answer.

You build Docker images at work. The question is whether you know *what is in them*, whether anyone tampered with them between build and deploy, and whether you can prove it to a compliance audit.

---

## Reproducible builds with BuildKit

BuildKit is the build engine behind `docker build` since Docker 23.0 and the default in `docker buildx`. It enables the primitives needed for reproducible, cacheable, auditable builds.

### Layer caching that survives across machines

```dockerfile
# syntax=docker/dockerfile:1.7

FROM python:3.11-slim@sha256:a8b43f8b5b7e2d3c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7

# Mount pip cache — persists across builds, not written into the final image layer
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --upgrade pip

WORKDIR /app
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt

COPY src/ ./src/
CMD ["python", "-m", "src.main"]
```

`--mount=type=cache` is a BuildKit-specific mount that injects a reusable cache directory during the `RUN` step but does not include it in the image layer. The cache is keyed per host by default; in CI, use `--cache-from` / `--cache-to` with a registry backend.

```yaml
# GitHub Actions with registry cache
- uses: docker/build-push-action@v6
  with:
    context: .
    push: true
    tags: ghcr.io/myorg/myapp:${{ github.sha }}
    cache-from: type=registry,ref=ghcr.io/myorg/myapp:buildcache
    cache-to: type=registry,ref=ghcr.io/myorg/myapp:buildcache,mode=max
```

`mode=max` caches all intermediate layers, not just the final image. This maximizes cache reuse at the cost of more registry storage — worth it for builds that take over 2 minutes.

### Determinism in the image

```dockerfile
# Bad — mutable tag; different registries may serve a different image at any time
FROM python:3.11-slim
RUN apt-get install -y curl

# Good — pinned to digest; immutable; any deviation is detectable
FROM python:3.11-slim@sha256:a8b43f8b5b7e2d3c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7

# Bad — apt-get without pinned versions; different runs may install different packages
RUN apt-get install -y curl

# Good — pinned versions
RUN apt-get install -y curl=7.88.1-10+deb12u5
```

Pin the base image digest, not just the tag. Tags are mutable — a registry operator can push a new image to `python:3.11-slim` and your next build silently changes. A digest is a cryptographic hash of the image manifest; it cannot be reassigned.

Automate digest updates with Dependabot or Renovate — they open PRs when new digests are available, giving you visibility and a controlled update path.

---

## Multi-arch builds

A `linux/amd64` image does not run on an M2 Mac (`linux/arm64`) or on an AWS Graviton instance (`linux/arm64/v8`) without emulation. Emulation is slow and masks architecture-specific bugs. Build for both:

```yaml
- uses: docker/setup-buildx-action@v3
  with:
    platforms: linux/amd64,linux/arm64

- uses: docker/build-push-action@v6
  with:
    platforms: linux/amd64,linux/arm64
    push: true
    tags: ghcr.io/myorg/myapp:${{ github.sha }}
```

This pushes a **manifest list** (also called an OCI image index) — a single tag that resolves to the correct architecture on the pulling machine. `docker pull` automatically selects the right variant.

The build runs QEMU emulation for the non-native architecture in the CI runner. That means an `arm64` build on an `x86_64` CI runner is slower (2–4×). Mitigate: use native ARM runners for the `arm64` leg via a matrix, or accept slower CI for the arch-specific leg.

```yaml
strategy:
  matrix:
    include:
      - platform: linux/amd64
        runs-on: ubuntu-24.04
      - platform: linux/arm64
        runs-on: ubuntu-24.04-arm   # GitHub's native ARM runner
```

---

## Image scanning: trivy and grype

Scanning checks the image's installed packages and language dependencies against known CVE databases (NVD, GitHub Advisory, OSV).

### trivy (the industry default)

```bash
# scan a local image
trivy image --severity HIGH,CRITICAL myapp:dev

# scan and fail the pipeline on HIGH or CRITICAL
trivy image --exit-code 1 --severity HIGH,CRITICAL myapp:dev

# output as SARIF (for GitHub security tab upload)
trivy image --format sarif --output trivy-results.sarif myapp:dev
```

```yaml
# In GitHub Actions — scan + upload to Security tab
- name: Scan image
  uses: aquasecurity/trivy-action@0.28.0
  with:
    image-ref: ghcr.io/myorg/myapp:${{ github.sha }}
    format: sarif
    output: trivy-results.sarif
    severity: HIGH,CRITICAL
    exit-code: '1'

- name: Upload results to Security tab
  uses: github/codeql-action/upload-sarif@v3
  if: always()
  with:
    sarif_file: trivy-results.sarif
```

The `if: always()` on the upload is essential — you want the SARIF results in the Security tab precisely when the scan *fails*, not only when it passes.

### Scanning scope

trivy checks three surfaces by default:

| Surface | What it finds |
|---------|---------------|
| OS packages | `apt`/`apk`/`rpm` packages with known CVEs (e.g. `libssl` versions) |
| Language dependencies | `pip`, `npm`, `go.sum`, `Cargo.lock` packages with known advisories |
| Misconfigurations | Dockerfile best-practice violations (running as root, `COPY . .` with secrets, etc.) |

Pass `--scanners vuln,misconfig,secret` to run all three surfaces in one pass.

---

## SBOMs with syft

An SBOM (Software Bill of Materials) is a machine-readable inventory of every package in your image. It answers the "what is in this image" question in a format auditors, compliance tools, and vulnerability scanners can consume.

```bash
# generate CycloneDX SBOM for an image
syft ghcr.io/myorg/myapp:abc123 -o cyclonedx-json > sbom.cdx.json

# generate SPDX (the other dominant format)
syft ghcr.io/myorg/myapp:abc123 -o spdx-json > sbom.spdx.json

# attach SBOM as an OCI artifact (same registry, linked to the image by digest)
cosign attach sbom --sbom sbom.cdx.json ghcr.io/myorg/myapp@sha256:<digest>
```

When the next Log4Shell-equivalent drops, you run `grep -r '"log4j"' sbom.cdx.json` across every SBOM in your registry and know in seconds which images are affected — instead of manually auditing Dockerfiles across 30 repos.

---

## Signing and verification with cosign / sigstore

Signing answers: "did the entity I trust actually produce this image, or was it tampered with between the pipeline and my cluster?"

### Keyless signing (the modern approach)

cosign's keyless mode uses the Sigstore infrastructure — your CI job authenticates via OIDC (GitHub, Google, etc.), Sigstore's Fulcio issues a short-lived certificate, and cosign records the signature in the public Rekor transparency log.

```yaml
# In GitHub Actions
- name: Sign image
  env:
    COSIGN_EXPERIMENTAL: '1'
  run: |
    cosign sign \
      --yes \
      ghcr.io/myorg/myapp@${{ steps.build.outputs.digest }}
```

The signature is stored in the registry alongside the image (as an OCI artifact). No key management required.

### Verification at deploy time

In Kubernetes, enforce image signature verification with a policy admission controller (Kyverno or OPA/Gatekeeper):

```yaml
# Kyverno ClusterPolicy — reject pods with unsigned images
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-images
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-image-signature
      match:
        resources:
          kinds: [Pod]
      verifyImages:
        - image: "ghcr.io/myorg/*"
          attestors:
            - entries:
                - keyless:
                    subject: "https://github.com/myorg/myapp/.github/workflows/ci.yml@refs/heads/main"
                    issuer: "https://token.actions.githubusercontent.com"
```

This policy rejects any pod whose image wasn't signed by *this specific workflow file on `main`*. A manually-pushed image from a developer's laptop — even from the same GHCR org — is rejected.

### With a static key (offline signing)

For air-gapped environments or compliance requirements that disallow Sigstore:

```bash
# Generate a key pair (do this once; store the private key in a secret manager)
cosign generate-key-pair

# Sign
cosign sign --key cosign.key ghcr.io/myorg/myapp@sha256:<digest>

# Verify
cosign verify --key cosign.pub ghcr.io/myorg/myapp@sha256:<digest>
```

---

## SLSA provenance

SLSA (Supply-chain Levels for Software Artifacts) is a framework for describing *how* an artifact was built — the source, the build system, the inputs. A SLSA Level 2 attestation proves:

- The artifact came from a specific commit in a specific repo
- The build ran on a hosted build service (not someone's laptop)
- The inputs and outputs are recorded

```yaml
# Use the official SLSA generator action
- uses: slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@v2.0.0
  with:
    image: ghcr.io/myorg/myapp
    digest: ${{ steps.build.outputs.digest }}
```

This generates a signed provenance attestation (SLSA Level 3 for containers) and attaches it to the image in the registry. Verify:

```bash
slsa-verifier verify-image \
  --source-uri github.com/myorg/myapp \
  ghcr.io/myorg/myapp@sha256:<digest>
```

SLSA provenance is the evidence that answers the supply-chain audit question: "is this exactly what was built from commit `abc123` on 2025-10-31, and has no one inserted code between the pipeline and the registry?"

---

## Pinning base images by digest — the full workflow

```bash
# Find the current digest for a tag
docker buildx imagetools inspect python:3.11-slim \
  --format '{{ json .Manifest }}' | grep -o '"digest":"sha256:[a-f0-9]*"' | head -1

# Or use crane (more reliable)
crane digest python:3.11-slim
```

Then in your Dockerfile:

```dockerfile
FROM python:3.11-slim@sha256:a8b43f8b5b7e2d3c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7
```

Renovate automates this: it opens PRs titled "Update base image python:3.11-slim to sha256:newdigest" with the changelog, letting you review and merge rather than forgetting.

---

## Debugging Containers: Build, Scan & Sign

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| CVE noise: scanner reports 200 CVEs, team stops looking | Default scan threshold is too low; base image has unpatched OS-level CVEs that have no upstream fix yet | Filter to `--severity HIGH,CRITICAL`; add a `.trivyignore` for CVE IDs with a `# reason` comment and an expiry date; switch to a distroless or scratch base to eliminate OS packages entirely |
| Unsigned images reach production silently | Kyverno/Gatekeeper policy is in `Audit` mode, not `Enforce`; or the namespace is not covered by the policy | Switch `validationFailureAction: Audit` to `Enforce`; check that the namespace selector matches the workload namespace; test with `kubectl run unsigned --image=ubuntu:22.04` and expect a reject |
| Cache poisoning: a malicious `buildcache` tag is pushed to GHCR | The build job pulls `buildcache` from the registry without verifying its integrity; an attacker who has write access to GHCR can inject a compromised cache layer | Scope the GHCR token with `packages: write` only to the specific build job; sign the build cache tag; never pull `buildcache` tags in an environment where `packages: write` is in scope for untrusted PRs — use `pull_request_target` carefully or disable cache for fork PRs |
| Multi-arch build fails: "exec format error" on arm64 | QEMU is not set up; or the base image doesn't have an arm64 variant | Add `docker/setup-qemu-action@v3` before the build step; verify `docker buildx inspect` shows `linux/arm64` as a supported platform |
| `cosign sign` fails: "no OIDC token available" | `id-token: write` permission is missing from the job; or the workflow is triggered by `pull_request` from a fork (fork PRs don't receive OIDC tokens) | Add `permissions: id-token: write`; for fork PRs, use `pull_request_target` and restrict it carefully, or skip signing for fork PRs |
| `trivy` finds a HIGH CVE in a base image with no upstream patch | The OS vendor hasn't released a fix; trivy marks it HIGH/CRITICAL based on NVD score | Add to `.trivyignore` with a reason and a review date; switch to a base image from a distro that patches faster (e.g. Wolfi, Chainguard); alternatively, build FROM scratch with only the compiled binary |
| SBOM is empty or missing language packages | `syft` was run against a built image where the package manager cache was cleaned; or the SBOM was generated before `pip install` ran | Run `syft` against the final image after all installs; confirm with `syft myapp:dev | grep python` that Python packages appear |

### Diagnosing CVE noise — the triage method

```bash
# Get the full trivy report before filtering
trivy image --format json --output report.json myapp:dev

# Count by severity to understand the distribution
python3 -c "
import json, collections
d = json.load(open('report.json'))
sevs = collections.Counter()
for r in d.get('Results', []):
    for v in r.get('Vulnerabilities', []) or []:
        sevs[v['Severity']] += 1
for s, n in sorted(sevs.items()):
    print(f'{s}: {n}')
"

# List only the HIGH/CRITICAL with a fix available
trivy image \
  --severity HIGH,CRITICAL \
  --ignore-unfixed \
  myapp:dev
```

`--ignore-unfixed` removes CVEs where the upstream package has no fixed version. These are real risks but not actionable — track them in a separate issue, don't let them block every merge.

> **War story.** A team's pipeline scanned with `trivy image --severity LOW,MEDIUM,HIGH,CRITICAL --exit-code 1` and promptly found 347 CVEs on day one, most of them MEDIUM severity in OS packages with no upstream fix. Engineers started adding `|| true` to the trivy step to unblock their PRs. Within two weeks, the scan gate was dead. The fix was not more rules — it was a tighter default: `--severity HIGH,CRITICAL --ignore-unfixed`. That left 8 actionable CVEs. The team fixed 6 in one afternoon (base image upgrade), added 2 to `.trivyignore` with documented reasons and a 30-day review date, and the gate became something engineers trusted instead of routed around. A security gate that produces 347 findings is not a gate. It is noise with a green checkbox attached.

---

## Checkpoint

You're ready for the challenges when you can answer without hesitation:

1. Explain why `FROM python:3.11-slim` is non-reproducible and `FROM python:3.11-slim@sha256:...` is reproducible — specifically what happens when a new digest is pushed to the tag.
2. Write the `docker/build-push-action` YAML snippet that enables registry-based BuildKit caching with `mode=max`.
3. Describe the three scanning surfaces trivy checks in a single `--scanners vuln,misconfig,secret` invocation.
4. State what an SBOM contains, what format choices you have, and how you'd use it during a Log4Shell-equivalent incident.
5. Explain cosign keyless signing: what OIDC claim is used, what Fulcio does, where the signature is stored, and how you verify it.
6. Write the Kyverno policy spec that rejects pods whose images aren't signed by a specific GitHub Actions workflow on `main`.
7. Describe the triage method for a trivy scan that returns 300+ CVEs: the two flags that reduce noise to actionable findings, and how you handle CVEs with no upstream fix.
8. Name the GitHub Actions permission required to call `cosign sign` in keyless mode, and explain why fork PRs cannot use keyless signing.
9. Explain what SLSA Level 2 provenance proves about an artifact, and how you verify it with `slsa-verifier`.

➡ Next up: **Deployment Strategies** — blue-green, canary, progressive delivery, and how to roll back without a rollback.
