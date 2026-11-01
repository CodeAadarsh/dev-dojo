# Solution: Generate a SLSA Provenance Attestation

## Understanding the format

An **in-toto Statement** is a JSON envelope with three top-level fields:

```
_type          — URI identifying the statement schema
subject        — what artifact this attestation is about (name + digest)
predicateType  — URI identifying the predicate schema
predicate      — the actual claim (SLSA provenance, SPDX SBOM, etc.)
```

A **SLSA Provenance v0.2 predicate** captures the full build context:

```
builder    — which build platform ran the build (identity URI)
buildType  — which workflow/schema was used (URI)
invocation — how the build was invoked: source repo, workflow file, parameters
materials  — every input consumed (source repo, base images, build dependencies)
```

## Part 1 — `generate_attestation.py`

```python
#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path

WORK = Path(__file__).parent


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def generate_attestation(artifact_path: Path, metadata_path: Path) -> dict:
    meta = json.loads(metadata_path.read_text())
    digest = sha256_file(artifact_path)
    return {
        "_type": "https://in-toto.io/Statement/v0.1",
        "subject": [
            {
                "name": artifact_path.name,
                "digest": {"sha256": digest}
            }
        ],
        "predicateType": "https://slsa.dev/provenance/v0.2",
        "predicate": {
            "builder":    meta["builder"],
            "buildType":  meta["buildType"],
            "invocation": meta["invocation"],
            "materials":  meta["materials"]
        }
    }


if __name__ == "__main__":
    artifact = WORK / "artifact.bin"
    metadata = WORK / "build_metadata.json"
    attestation = generate_attestation(artifact, metadata)
    out = WORK / "attestation.json"
    out.write_text(json.dumps(attestation, indent=2))
    print(f"Attestation written to {out}")
```

### Why compute the digest instead of hard-coding it?

The entire point of provenance is that the digest is *derived from the artifact bytes at the time the attestation is created*, not copied from somewhere. Hard-coding a digest defeats tamper detection: if the artifact bytes change after the attestation is created, the hard-coded digest still "matches" because it was never tied to the actual bytes.

`hashlib.sha256()` is used instead of `subprocess("sha256sum")` because it avoids a shell dependency and is guaranteed to produce the same byte-level result on every OS. Read the file in binary mode (`read_bytes()`), not text mode — text mode on Windows would translate `\r\n` → `\n` and produce a different digest.

## Part 2 — `check_attestation.py`

```python
#!/usr/bin/env python3
import hashlib
from pathlib import Path


def sha256_file(path) -> str:
    h = hashlib.sha256()
    h.update(Path(path).read_bytes())
    return h.hexdigest()


def check_attestation(attestation: dict, artifact_path) -> bool:
    if attestation.get("_type") != "https://in-toto.io/Statement/v0.1":
        return False
    if attestation.get("predicateType") != "https://slsa.dev/provenance/v0.2":
        return False
    expected_digest = sha256_file(artifact_path)
    subjects = attestation.get("subject", [])
    digest_ok = any(
        s.get("digest", {}).get("sha256") == expected_digest
        for s in subjects
    )
    if not digest_ok:
        return False
    pred = attestation.get("predicate", {})
    if not pred.get("builder", {}).get("id"):
        return False
    return True
```

### Why return `False` instead of raising exceptions?

A verifier that raises on invalid input exposes internal structure to callers and complicates integration into pipelines (a non-zero exit code from an uncaught exception looks the same as a crash). Returning `False` keeps the contract clean: callers check the boolean, not exception types. The hidden tests assert `is False` (not `is not True`), so a `None` return from an incomplete stub would also fail — implement it explicitly.

### Why check `_type` and `predicateType` first?

These are the schema discriminators. An attestation missing `_type` could be anything — a different JSON schema, a truncated file, a tampered payload that replaced the type. Checking them first means every subsequent field access is guaranteed to be against the expected schema version. This is the same reason HTTP status codes are checked before response bodies in client code.

## Run and verify

```bash
cd ~/.kube-dojo-work/06-provenance-attestation
python3 generate_attestation.py
.venv/bin/pytest tests/ -v
bash courses/course-30-supply-chain-security/challenges/06-provenance-attestation/verify.sh
```

## Attacker's view

A SLSA provenance attestation without cryptographic binding (signing) is a social document — anyone can write it. The attacker's move is to produce a fake attestation claiming the malicious binary was built from a trusted source commit. This is why in practice:

1. The attestation is **signed** using `cosign attest` (Challenge 04's signing, applied to the attestation document rather than the binary directly).
2. The signature is stored in an **OCI registry** alongside the image, or in **Rekor** as a transparency log entry.
3. The **admission controller** (Kyverno from Challenge 05) verifies both the image signature *and* the attached attestation before admitting the pod.

Together, Challenges 04 + 05 + 06 form a complete SLSA L2 pipeline: sign the artifact, generate and sign the provenance, enforce admission by checking both.

## `cosign attest` — the production version

```bash
# Sign the attestation with cosign (stores it in the OCI registry as an OCI artifact)
cosign attest \
  --key cosign.key \
  --predicate attestation.json \
  --type slsaprovenance \
  ghcr.io/your-org/hello-go:v1.4.2

# Verify the attestation at admission (or in a pipeline check)
cosign verify-attestation \
  --key cosign.pub \
  --type slsaprovenance \
  ghcr.io/your-org/hello-go:v1.4.2 \
  | jq '.payload | @base64d | fromjson | .predicate.builder.id'
```

The `cosign attest` command wraps the predicate in a DSSE (Dead Simple Signing Envelope), signs the envelope, and pushes the whole thing to the registry as a referrer to the original image manifest. No separate file storage needed — the attestation travels with the image.
