# Image Signing

Three weeks ago, your team's CI pipeline was compromised. An attacker got write access to the registry and pushed a backdoored `api:latest` image with identical tag. By the time the incident was detected, 12 pods were running the malicious image. The postmortem action item: **sign all images with cosign**.

Cosign is a tool from the Sigstore project that lets you sign OCI images and store the signature in the same registry as the image. Anyone with the public key can verify that the image hasn't been tampered with since it was signed.

---

## How cosign signatures work

```
                     ┌─────────────────────────────────────────┐
                     │          OCI Registry                    │
                     │                                          │
  docker push ──────►│  dojo/api:1.0  ──── sha256:abc123       │
                     │                                          │
  cosign sign ──────►│  sha256-abc123.sig  (OCI artifact,      │
   (attaches sig)    │   references dojo/api@sha256:abc123)     │
                     └─────────────────────────────────────────┘
```

The signature is a separate OCI artifact stored alongside the image. It is linked to the **image digest** (not the tag), so you can verify that the specific bytes you pulled are what was signed — even if the tag has been moved.

---

## Mission

A local registry has been started with an unsigned `dojo/api:1.0` image pushed to it. You need to:

1. Install `cosign` (if not already installed)
2. Generate a signing key pair
3. Sign the image in the local registry
4. Mark the Deployment as signed via annotation
5. Prove the pod is still Running

**The verifier checks:**

1. Deployment `api` in `dojo-docker-signing` has annotation `dojo.docker/signed: true`
2. At least one pod is in `Running` state

Run the verifier:

```bash
bash courses/course-37-docker-internals/challenges/13-image-signing/verify.sh
```
