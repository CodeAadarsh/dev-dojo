# Sign and Verify Artifacts with cosign

The post-mortem hits your inbox at 2 AM: *"A release tarball was silently replaced on the CDN between the release job and the production deploy. The deploy ran, the binary had no signature, and nobody noticed until a customer's EDR flagged an unexpected syscall sequence three days later."*

Signing a build artifact is the cheapest tamper-detection control you can bolt onto a pipeline. `cosign sign-blob` uses an asymmetric key to produce a signature over the SHA-256 digest of any file. Anyone holding the public key can verify it at any later stage — in a deploy script, a CI gate, an admission hook. One byte changed anywhere in the file invalidates the signature (avalanche effect). No key = no forgery.

## Prerequisites

`cosign` must be installed:

```bash
# macOS
brew install cosign

# Linux
curl -sSL https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64 \
  -o /usr/local/bin/cosign && chmod +x /usr/local/bin/cosign

# Confirm
cosign version
```

## Setup

```bash
bash courses/course-30-supply-chain-security/challenges/04-sign-and-verify/setup.sh
```

Plants two files in your work directory:

```
~/.kube-dojo-work/04-sign-and-verify/
├── artifact.bin          — the build output to protect
└── artifact.tampered.bin — a modified copy; verification must reject this
```

## Mission

Working from `~/.kube-dojo-work/04-sign-and-verify/`:

1. Generate a cosign key pair — you need `cosign.key` (private) and `cosign.pub` (public) in the work directory.
2. Sign `artifact.bin`; write the base64-encoded signature to `artifact.sig`.
3. Confirm `cosign verify-blob` succeeds on `artifact.bin` with your key.
4. Confirm `cosign verify-blob` **fails** on `artifact.tampered.bin` with the same signature.

The verifier checks all four conditions before printing the flag.

## What the verifier checks

| File | Required condition |
|------|--------------------|
| `cosign.pub` | exists in work dir |
| `artifact.bin` | exists in work dir |
| `artifact.sig` | exists in work dir; valid signature over `artifact.bin` under `cosign.pub` |
| `artifact.tampered.bin` | exists; `cosign verify-blob` with the same key+signature **exits non-zero** |

## Why this matters

Without signing, your deploy pipeline implicitly trusts every network hop: the CDN, the object-store bucket, the artifact registry, the build cache. A signing step moves trust to the key pair: as long as the private key is protected, any transit or storage tampering is detectable before execution.

The next level is keyless signing via OIDC (no long-lived private key to leak) and a transparency log (Rekor) that records every signature event — covered in the module discussion and mirrored in Challenge 06 when you generate a full provenance attestation.

## Verify

```bash
bash courses/course-30-supply-chain-security/challenges/04-sign-and-verify/verify.sh
```
