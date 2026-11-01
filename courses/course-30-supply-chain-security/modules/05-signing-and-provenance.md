# Signing & Provenance

> **Module 05 · Course 30** — A container image is just a tarball. A tag is a mutable pointer. Neither proves *who* built the image, *when*, or *from what source*. Signing and provenance close that gap — and once you understand the threat model, you'll see why "it came from our registry" is not a safety guarantee.

You already know how to build and push images. This module is about what happens *after* push that makes those images trustworthy at pull time — and what the SLSA framework says about how much trust each approach actually earns.

---

## The threat model: why signing exists

Consider what can go wrong between `git push` and a pod running in production:

| Attack vector | What the attacker does | Mitigated by |
|---------------|------------------------|--------------|
| Tag hijack | Overwrites `:v2.4.1` on Docker Hub after your CI referenced it | Digest pinning + signature |
| Repo-jacking | Original maintainer deletes account; attacker registers the same namespace | Signature tied to original OIDC identity |
| CI compromise | Attacker injects a modified layer into the build | Signed provenance proving build inputs |
| Registry MITM | Attacker intercepts the pull and serves a different image | Signature verified against immutable Rekor log |
| Insider | A developer pushes a backdoored image directly without going through CI | Required: CI identity (not human key) on every release image |

A signature does exactly one thing: it proves **this exact digest was signed by a specific identity at a specific time**. Combined with the immutable Rekor transparency log, it becomes non-repudiable — if a signature exists in Rekor, it can't be silently removed later.

---

## Sigstore: the architecture

Sigstore is a set of open-source components that make signing as low-friction as `git commit`. The three pieces:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Sigstore ecosystem                              │
│                                                                          │
│  cosign (CLI)           Fulcio (CA)            Rekor (log)               │
│  ┌───────────┐         ┌───────────┐          ┌───────────┐             │
│  │ signs,    │─OIDC──▶│ issues    │──entry──▶│ immutable │             │
│  │ attests,  │  token  │ ephemeral │          │ append-   │             │
│  │ verifies  │◀─cert──│ x.509     │          │ only      │             │
│  └───────────┘         │ cert      │          │ Merkle    │             │
│        │               └───────────┘          │ tree      │             │
│        │                                      └─────▲─────┘             │
│        └──────────────── signature ─────────────────┘                   │
└─────────────────────────────────────────────────────────────────────────┘
```

**Fulcio** is a certificate authority that issues *short-lived* (5-minute) x.509 certs binding an ephemeral public key to an OIDC identity (e.g., `github-actions@company.iam.gserviceaccount.com` or `alice@example.com`). The cert lives just long enough to sign; after that it's useless.

**Rekor** is a public, append-only, Merkle-tree-backed transparency log. Every signature entry is timestamped and inclusion-proven. You can run your own (`docker run -d -p 3000:3000 gcr.io/projectsigstore/rekor-server`) but the public instance at `rekor.sigstore.dev` is the default.

**cosign** is the CLI that orchestrates this: fetch OIDC token → request Fulcio cert → sign image digest → upload entry to Rekor → push signature as OCI artifact to the registry.

### Keyless vs keyed signing

| Approach | Key management | Identity claim | Best for |
|----------|---------------|----------------|----------|
| **Keyless (OIDC)** | None — ephemeral key, discarded after signing | OIDC subject (CI job, user email) | CI pipelines, teams without PKI |
| **Keyed** | You own the keypair, stored in KMS/HSM | SHA of the public key | Air-gapped, regulated, audit-trail needed |

Keyless is the default and the harder concept. The private key never touches disk and never needs to be rotated. Trust is rooted in your OIDC provider (GitHub Actions, Google, Sigstore's own Dex).

---

## Signing images: the exact commands

### In a GitHub Actions CI pipeline (keyless)

```yaml
# .github/workflows/release.yml
- name: Sign image
  env:
    COSIGN_EXPERIMENTAL: "1"  # enables keyless / OIDC flow
  run: |
    cosign sign \
      --oidc-issuer=https://token.actions.githubusercontent.com \
      ghcr.io/myorg/myapp@${{ steps.push.outputs.digest }}
```

Sign the **digest**, not the tag. Tags are mutable; the digest is what's actually running.

### Manually with a key (for testing on the dojo cluster)

```bash
# generate a keypair — cosign.key is encrypted with a passphrase
cosign generate-key-pair

# sign a local image after pushing
cosign sign --key cosign.key \
  ghcr.io/myorg/myapp:v1.0.0

# verify it
cosign verify --key cosign.pub \
  ghcr.io/myorg/myapp:v1.0.0
```

### Verifying a keyless signature

```bash
cosign verify \
  --certificate-identity="https://github.com/myorg/myapp/.github/workflows/release.yml@refs/heads/main" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  ghcr.io/myorg/myapp:v1.0.0
```

The `--certificate-identity` is the OIDC subject from the Fulcio cert. For GitHub Actions it's the workflow ref. This is the field you want to lock down: it prevents a signature from a *different* repo or branch being accepted as valid.

### Signing blobs (not just images)

cosign can sign any artifact — a binary, an SBOM file, a tarball:

```bash
cosign sign-blob --key cosign.key \
  --bundle myapp-v1.0.0.tar.gz.bundle \
  myapp-v1.0.0.tar.gz

cosign verify-blob --key cosign.pub \
  --bundle myapp-v1.0.0.tar.gz.bundle \
  myapp-v1.0.0.tar.gz
```

The `--bundle` file contains the signature + Rekor entry in one portable file. Useful for offline verification or release artifacts distributed outside OCI registries.

---

## Attestations and in-toto

A signature only proves "this digest was signed by X." An **attestation** carries a richer signed payload — build inputs, test results, SBOM — in the [in-toto](https://in-toto.io/) format:

```
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://slsa.dev/provenance/v0.2",
  "subject": [{ "name": "ghcr.io/myorg/myapp", "digest": { "sha256": "abc123..." } }],
  "predicate": {
    "builder": { "id": "https://github.com/myorg/myapp/.github/workflows/release.yml" },
    "buildType": "...",
    "invocation": { "configSource": { "uri": "git+https://github.com/myorg/myapp@main", "digest": {...} } },
    ...
  }
}
```

The three key fields: **subject** (what artifact this is about), **predicateType** (the schema of what follows), **predicate** (the actual data).

```bash
# attach an SBOM as an attestation
cosign attest --key cosign.key \
  --predicate sbom.spdx.json \
  --type spdxjson \
  ghcr.io/myorg/myapp@sha256:abc123...

# attach SLSA provenance (generated by SLSA GitHub generator)
cosign attest --key cosign.key \
  --predicate provenance.json \
  --type slsaprovenance \
  ghcr.io/myorg/myapp@sha256:abc123...

# download and inspect attached attestations
cosign download attestation ghcr.io/myorg/myapp:v1.0.0 | \
  jq -r '.payload' | base64 -d | jq .
```

---

## SLSA levels: what each actually guarantees

SLSA (Supply-chain Levels for Software Artifacts) is a framework, not a tool. The levels describe *how much trust* you can place in a build's provenance.

| Level | Requirement | What an attacker needs to bypass |
|-------|-------------|----------------------------------|
| **L0** | No guarantee | Anything — no bar |
| **L1** | Provenance exists and is submitted | Compromise the developer's machine to forge it |
| **L2** | Hosted build, provenance signed by the build service | Compromise the build service (e.g., GitHub Actions account) |
| **L3** | Isolated build, auditable source + build config, provenance is non-falsifiable | Compromise the build platform itself (runner infra) |

Most regulated enterprise requirements target **L2**: your CI system signs the provenance, so a developer can't hand-craft a release. L3 adds build isolation — no other build's secrets or artifacts can influence yours.

> Key insight: SLSA levels are claims about the *build process*, not the *image contents*. An L3 image can still have a critical CVE. SLSA + SBOM + vulnerability scanning are complementary layers, not alternatives.

The [SLSA GitHub Generator](https://github.com/slsa-framework/slsa-github-generator) provides ready-made GitHub Actions workflows that produce L3 provenance attestations automatically.

---

## Debugging Signing & Provenance

Most production problems come down to three patterns: the signature is missing, the identity claims don't match, or Rekor is unreachable.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `cosign verify` → `no matching signatures` | Image was pushed without signing, or signed with a different key/identity | Check `cosign triangulate <image>` for the OCI tag where signatures live; confirm the sign step actually ran in CI |
| `cosign verify` → `verifying certificate: certificate expired` | Signing happened >5 minutes ago and the ephemeral cert timed out | Keyless certs expire — this is expected and non-fatal because the cert was recorded in Rekor *at signing time*. Pass `--insecure-ignore-sct` only to test; in production the Rekor entry is the proof |
| `cosign verify` → `failed to get SCT` | Rekor is unreachable from the verification machine | Check network egress to `rekor.sigstore.dev:443`; or run a private Rekor instance and pass `--rekor-url` |
| `cosign attest` → `DSSE signing` error | Predicate file is not valid JSON or the `--type` flag doesn't match | Validate your predicate JSON first: `python3 -m json.tool provenance.json` |
| Admission webhook rejects pod → `image policy webhook denied: no attestations found` | Attestation was attached to a *tag* reference, but the pod spec uses a digest reference (or vice versa) | Always sign and attest the **digest**, always deploy using the digest (`image: ghcr.io/org/app@sha256:...`) |
| Provenance verification passes but SLSA level claim is L1 when you expected L2 | CI signs the provenance but the signing step runs on a self-hosted, mutable runner | Self-hosted runners are L1 at best — move signing to a GitHub-hosted runner or use a dedicated ephemeral runner |

### Exact diagnostic commands

```bash
# what signatures are attached to this image?
cosign triangulate ghcr.io/myorg/myapp:v1.0.0
# -> ghcr.io/myorg/myapp:sha256-<digest>.sig

# list all cosign artifacts attached (sigs, attestations, SBOMs)
cosign tree ghcr.io/myorg/myapp:v1.0.0

# check a specific Rekor entry for a signature
cosign verify \
  --certificate-identity="..." \
  --certificate-oidc-issuer="..." \
  --rekor-url=https://rekor.sigstore.dev \
  ghcr.io/myorg/myapp:v1.0.0 2>&1 | head -30

# look up the Rekor log entry by UUID
rekor-cli get --uuid <uuid-from-verify-output>

# inspect a raw attestation without verifying the signature
cosign download attestation ghcr.io/myorg/myapp:v1.0.0 2>/dev/null | \
  python3 -c "import sys,json,base64; [print(base64.b64decode(json.loads(l)['payload']).decode()) for l in sys.stdin]"
```

> **War story.** A data pipeline team at an enterprise cloud company pinned their base image to `python-data:3.11.4` — not the digest, the tag. Three weeks after their last release, an incident report came in: the upstream maintainer's Docker Hub account had expired and been hijacked. The attacker overwrote the `:3.11.4` tag with a version that exfiltrated environment variables on startup. The pipeline ran for six hours before the egress anomaly was caught. The team had a CI pipeline that built and pushed images, but no signing step — there was no way to prove the image running in production was the same one CI built. A cosign sign step on every push, combined with `cosign verify` as the first step of the deployment job, would have caught the substitution the moment the compromised image was deployed: the digest in the registry no longer matched any known-signed digest, so verification would have failed and the deployment would never have proceeded.

---

## Checkpoint

You're ready for the signing challenges when you can, without looking anything up:

1. Explain why signing a tag is less secure than signing a digest, in one sentence.
2. Describe the keyless signing flow: what Fulcio issues, what Rekor records, and why the private key can be discarded.
3. State the difference between a signature and an attestation, and give an example of a predicate type useful for supply-chain security.
4. Explain what SLSA L2 guarantees that L1 does not, and what an attacker would need to forge L2 provenance.
5. Reproduce the symptom and fix for "no matching signatures" — what command tells you whether *any* signature is attached?
6. Name two flags you must pass to `cosign verify` in keyless mode, and explain what each pins.
7. Given a running pod in production, describe the chain of evidence you'd follow to prove or disprove that it was built from a specific git commit.

➡ Next up: **Admission Enforcement** — knowing how to sign is only half the work; the cluster needs to *refuse* unsigned images before they run.
