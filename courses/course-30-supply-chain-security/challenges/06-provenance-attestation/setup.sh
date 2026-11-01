#!/usr/bin/env bash
# Plants the "Generate a SLSA Provenance Attestation" scenario.
# Idempotent — safe to re-run.
set -euo pipefail

SLUG="06-provenance-attestation"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── artifact.bin ─────────────────────────────────────────────────────────────
printf '%s\n%s\n%s\n%s\n' \
  'build-output: dojo-hello-go-v1.4.2' \
  'commit: 7f3c2a8e1b5d9f0a4c6e8b2d4f1a3e6c' \
  'built-by: github-actions/2.320.0' \
  'timestamp: 2026-11-01T06:12:34Z' \
  > "$WORK/artifact.bin"

# ── build_metadata.json ───────────────────────────────────────────────────────
cat > "$WORK/build_metadata.json" << 'JSON'
{
  "builder": {
    "id": "https://github.com/actions/runner/releases/tag/v2.320.0"
  },
  "buildType": "https://github.com/slsa-framework/slsa-github-generator/go@v1",
  "invocation": {
    "configSource": {
      "uri": "git+https://github.com/dojo-example/hello-go@refs/heads/main",
      "digest": { "sha1": "7f3c2a8e1b5d9f0a4c6e8b2d4f1a3e6c" },
      "entryPoint": ".github/workflows/release.yml"
    },
    "parameters": {},
    "environment": {
      "github_run_id": "9876543210",
      "github_run_attempt": "1"
    }
  },
  "materials": [
    {
      "uri": "git+https://github.com/dojo-example/hello-go@refs/heads/main",
      "digest": { "sha1": "7f3c2a8e1b5d9f0a4c6e8b2d4f1a3e6c" }
    }
  ]
}
JSON

# ── generate_attestation.py skeleton ──────────────────────────────────────────
cat > "$WORK/generate_attestation.py" << 'PYEOF'
#!/usr/bin/env python3
"""
Generate an in-toto Statement v0.1 with a SLSA Provenance v0.2 predicate.

Subject  : artifact.bin (the build output)
Predicate: builder, buildType, invocation, materials — sourced from build_metadata.json

Required statement shape
------------------------
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "subject": [
    {
      "name": "<artifact filename>",
      "digest": { "sha256": "<hex sha256 of the artifact bytes>" }
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
"""
import hashlib
import json
from pathlib import Path

WORK = Path(__file__).parent


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def generate_attestation(artifact_path: Path, metadata_path: Path) -> dict:
    """
    Return a dict representing an in-toto Statement v0.1.

    Steps:
    1. Read and parse metadata_path (JSON).
    2. Compute the SHA-256 digest of artifact_path.
    3. Build and return the statement dict.
    Do NOT hard-code the digest — compute it from the file.
    """
    # TODO: implement this function
    return {}


if __name__ == "__main__":
    artifact = WORK / "artifact.bin"
    metadata = WORK / "build_metadata.json"
    attestation = generate_attestation(artifact, metadata)
    out = WORK / "attestation.json"
    out.write_text(json.dumps(attestation, indent=2))
    print(f"Attestation written to {out}")
PYEOF

# ── check_attestation.py skeleton ────────────────────────────────────────────
cat > "$WORK/check_attestation.py" << 'PYEOF'
#!/usr/bin/env python3
"""
Validate an in-toto attestation against an artifact.

check_attestation(attestation, artifact_path) -> bool

Return True  : attestation is structurally valid AND the subject digest
               matches the actual SHA-256 of artifact_path.
Return False : digest mismatch, missing required field, or wrong statement
               type / predicate type.

Required checks (minimum — add more if you like):
  - _type      == "https://in-toto.io/Statement/v0.1"
  - predicateType == "https://slsa.dev/provenance/v0.2"
  - subject[*].digest.sha256 matches the computed digest of artifact_path
  - predicate.builder.id is a non-empty string
"""
import hashlib
from pathlib import Path


def sha256_file(path) -> str:
    h = hashlib.sha256()
    h.update(Path(path).read_bytes())
    return h.hexdigest()


def check_attestation(attestation: dict, artifact_path) -> bool:
    """
    Return True if valid, False otherwise. Do not raise exceptions.
    """
    # TODO: implement this function
    return False
PYEOF

# ── tests/test_attestation.py (visible) ──────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_attestation.py" << 'PYEOF'
"""
Visible local tests — run these while developing.
The verifier runs an equivalent (stricter) hidden harness.
"""
import json
import hashlib
import copy
import sys
from pathlib import Path

WORK = Path(__file__).parent.parent
sys.path.insert(0, str(WORK))

from generate_attestation import generate_attestation
from check_attestation import check_attestation


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def _make_attestation():
    return generate_attestation(WORK / "artifact.bin", WORK / "build_metadata.json")


def test_statement_type():
    att = _make_attestation()
    assert att.get("_type") == "https://in-toto.io/Statement/v0.1", \
        f"Expected _type 'https://in-toto.io/Statement/v0.1', got {att.get('_type')!r}"


def test_predicate_type():
    att = _make_attestation()
    assert att.get("predicateType") == "https://slsa.dev/provenance/v0.2"


def test_subject_digest_matches_artifact():
    att = _make_attestation()
    expected = _sha256(WORK / "artifact.bin")
    subjects = att.get("subject", [])
    assert subjects, "subject array must not be empty"
    assert any(s.get("digest", {}).get("sha256") == expected for s in subjects), \
        f"No subject has sha256={expected!r} — did you compute the digest from the file?"


def test_predicate_required_fields():
    pred = _make_attestation().get("predicate", {})
    assert pred.get("builder", {}).get("id"), "predicate.builder.id must be a non-empty string"
    assert pred.get("buildType"), "predicate.buildType must be non-empty"
    assert "invocation" in pred, "predicate.invocation is required"
    materials = pred.get("materials", [])
    assert isinstance(materials, list) and materials, "predicate.materials must be a non-empty list"


def test_verifier_accepts_good_attestation():
    att = _make_attestation()
    assert check_attestation(att, WORK / "artifact.bin") is True, \
        "check_attestation(good_attestation, artifact.bin) must return True"


def test_verifier_rejects_mismatched_digest():
    bad = copy.deepcopy(_make_attestation())
    bad["subject"][0]["digest"]["sha256"] = "0" * 64
    assert check_attestation(bad, WORK / "artifact.bin") is False, \
        "check_attestation must return False when subject digest does not match"


def test_verifier_rejects_missing_builder():
    bad = copy.deepcopy(_make_attestation())
    bad["predicate"]["builder"]["id"] = ""
    assert check_attestation(bad, WORK / "artifact.bin") is False, \
        "check_attestation must return False when predicate.builder.id is empty"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Files planted:"
echo "  artifact.bin             — build output (the attestation subject)"
echo "  build_metadata.json      — CI build facts (builder, invocation, materials)"
echo "  generate_attestation.py  — skeleton: implement generate_attestation()"
echo "  check_attestation.py     — skeleton: implement check_attestation()"
echo "  tests/test_attestation.py — visible tests to run locally"
echo
echo "Prerequisites:"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Develop:"
echo "  # implement both skeleton files, then:"
echo "  python3 generate_attestation.py          # produces attestation.json"
echo "  .venv/bin/pytest tests/ -v               # run visible tests"
echo
echo "Verify + flag:"
echo "  bash courses/course-30-supply-chain-security/challenges/06-provenance-attestation/verify.sh"
