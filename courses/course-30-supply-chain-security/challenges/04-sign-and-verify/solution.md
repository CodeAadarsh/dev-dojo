# Solution: Sign and Verify Artifacts with cosign

## Step 1 — Generate a key pair

```bash
cd ~/.kube-dojo-work/04-sign-and-verify
cosign generate-key-pair
```

You're prompted for a password (empty works for this lab). Two files appear:

- `cosign.key` — PKCS8-encrypted private key. Treat this like a production secret: never commit it, never log it.
- `cosign.pub` — The public key. Safe to distribute widely — this is the trust anchor for verification.

The key uses ECDSA P-256 by default. The private key is AES-256-encrypted with your password before being written to disk, so if the file is stolen without the password it's useless.

## Step 2 — Sign the artifact

```bash
cosign sign-blob --key cosign.key artifact.bin > artifact.sig
```

Internally: cosign computes `SHA-256(artifact.bin)`, signs the raw digest with the ECDSA private key, and writes the base64-encoded DER signature to stdout. The redirect captures it in `artifact.sig`.

The signature covers **only the digest**, not the key or any timestamp. This means:
- The same signature works anywhere `artifact.bin` is deployed, as long as the same public key is available.
- The signature is 88–96 bytes of base64 — trivial to attach to a release manifest or a pipeline artifact store.

## Step 3 — Verify the real artifact

```bash
cosign verify-blob --key cosign.pub --signature artifact.sig artifact.bin
# Verified OK
```

cosign recomputes `SHA-256(artifact.bin)`, decodes the base64 signature, and runs ECDSA verification against the public key. Exit 0 = signature valid.

## Step 4 — Confirm the tampered copy is rejected

```bash
cosign verify-blob --key cosign.pub --signature artifact.sig artifact.tampered.bin
# Error: failed to verify signature
```

`artifact.tampered.bin` has one character (`2` → `X`) different from `artifact.bin`. SHA-256 has the avalanche property: one bit changed in the input cascades through all 256 bits of the output. The digest cosign recomputes no longer matches the digest embedded in the signature, so ECDSA verification fails immediately — it doesn't even matter which byte changed.

## Run the verifier

```bash
bash courses/course-30-supply-chain-security/challenges/04-sign-and-verify/verify.sh
```

## Attacker's view

Without the private key, an attacker cannot forge a valid signature — ECDSA unforgeability reduces to the elliptic-curve discrete-log problem. The attack surface is therefore:

1. **Key theft** — stealing `cosign.key` plus the password. In production this means stolen CI secrets (GitHub Actions `COSIGN_PASSWORD` + `COSIGN_KEY`). Mitigation: keyless signing (see below).
2. **Public-key substitution** — if the attacker can swap `cosign.pub` in the pipeline, they become the trust root. Mitigation: embed the public key in the pipeline definition (in git, not fetched at runtime) and require a separate approval to rotate it.
3. **Transparency log gaps** — a re-signed artifact with a different key won't show up in the original Rekor entry. Mitigation: pin the expected key fingerprint in the verification step.

## Hardening preview — keyless signing

In GitHub Actions you don't need to store a private key at all:

```bash
# .github/workflows/release.yml
- name: Sign artifact
  env:
    COSIGN_EXPERIMENTAL: "1"
  run: cosign sign-blob --oidc-issuer https://token.actions.githubusercontent.com artifact.bin > artifact.sig
```

The Sigstore Rekor transparency log records the signer's OIDC identity (the Actions workflow identity), the digest, and a timestamp — with no long-lived secret to rotate or leak. Verification then checks against the transparency log instead of a local public key:

```bash
cosign verify-blob \
  --certificate-identity-regexp "https://github.com/your-org/.*" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  --signature artifact.sig \
  artifact.bin
```

## SLSA connection

Blob signing by itself satisfies part of SLSA L2: you can prove *which* artifact was released. The full provenance story — who built it, from what source commit, with what build platform — comes in Challenge 06 when you generate an in-toto attestation.
