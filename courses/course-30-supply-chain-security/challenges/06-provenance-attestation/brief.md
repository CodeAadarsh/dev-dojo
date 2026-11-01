# Generate a SLSA Provenance Attestation

The CVE triage ticket reads: *"CVE-2026-9921 in zlib 1.3.0 — confirm which production binaries are affected."* Your security team needs to know which build produced each artifact and which source version it came from. Nobody wrote it down. There are no build logs older than 30 days. There is no provenance.

**SLSA provenance** (Supply-chain Levels for Software Artifacts) is a machine-readable record answering: *what artifact, built how, from what source, by which builder?* The in-toto Statement format is the container; a SLSA Provenance v0.2 predicate is the contents. Together they give you the audit trail that turns "which binary has zlib 1.3.0?" from a multi-hour fire drill into a one-query lookup.

This challenge has two parts: produce the attestation, then implement a verifier that can validate — or reject — an attestation against an artifact.

## Setup

```bash
bash courses/course-30-supply-chain-security/challenges/06-provenance-attestation/setup.sh
```

Plants in your work directory:

```
~/.kube-dojo-work/06-provenance-attestation/
├── artifact.bin             — a mock build output (the subject of the attestation)
├── build_metadata.json      — build facts recorded by the CI system
├── generate_attestation.py  — skeleton: implement generate_attestation()
├── check_attestation.py     — skeleton: implement check_attestation()
└── tests/
    └── test_attestation.py  — visible tests you can run locally
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/06-provenance-attestation
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

### Part 1 — Implement `generate_attestation.py`

Fill in the body of `generate_attestation(artifact_path, metadata_path)`. It must return a `dict` representing an in-toto Statement v0.1 with a SLSA Provenance v0.2 predicate:

```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "subject": [
    {
      "name": "artifact.bin",
      "digest": { "sha256": "<sha256 of artifact.bin>" }
    }
  ],
  "predicateType": "https://slsa.dev/provenance/v0.2",
  "predicate": {
    "builder":    { "id": "..." },
    "buildType":  "...",
    "invocation": { "configSource": { ... } },
    "materials":  [ { "uri": "...", "digest": { ... } } ]
  }
}
```

The predicate fields come from `build_metadata.json`. The subject digest is the actual SHA-256 of `artifact.bin` — compute it, don't hard-code it.

Then run it to produce `attestation.json`:

```bash
python3 ~/.kube-dojo-work/06-provenance-attestation/generate_attestation.py
```

### Part 2 — Implement `check_attestation.py`

Fill in `check_attestation(attestation: dict, artifact_path) -> bool`. It must:

- Return `True` if the attestation is structurally valid **and** `subject[*].digest.sha256` matches the actual SHA-256 of `artifact_path`.
- Return `False` if the digest does not match the artifact.
- Return `False` if `predicate.builder.id` is empty or missing.

The verifier uses this function to confirm it correctly rejects tampered and incomplete attestations.

## What the verifier checks

| Test | Description |
|------|-------------|
| `test_statement_type` | `_type` = `"https://in-toto.io/Statement/v0.1"` |
| `test_predicate_type` | `predicateType` = `"https://slsa.dev/provenance/v0.2"` |
| `test_subject_digest_matches_artifact` | `subject[*].digest.sha256` = actual SHA-256 of `artifact.bin` |
| `test_predicate_required_fields` | `builder.id`, `buildType`, `invocation`, `materials` all present and non-empty |
| `test_verifier_accepts_good_attestation` | `check_attestation(good_att, artifact.bin)` returns `True` |
| `test_verifier_rejects_mismatched_digest` | `check_attestation(att_with_wrong_digest, artifact.bin)` returns `False` |
| `test_verifier_rejects_missing_builder` | `check_attestation(att_with_empty_builder_id, artifact.bin)` returns `False` |

## SLSA levels in context

| Level | What it requires | This challenge |
|-------|-----------------|---------------|
| L1 | Build is scripted, produces provenance | Covered: you generate the attestation |
| L2 | Hosted build platform, provenance signed by platform | Covered in signing: `cosign attest` from Challenge 04 |
| L3 | Hermetic build, non-forgeable provenance | Out of scope for the dojo; requires SLSA builders |

Challenge 04 (cosign blob signing) + this challenge together get you to L2: a signed artifact with a cryptographically bound provenance record.

## Verify

```bash
bash courses/course-30-supply-chain-security/challenges/06-provenance-attestation/verify.sh
```
