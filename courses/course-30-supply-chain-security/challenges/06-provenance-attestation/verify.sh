#!/usr/bin/env bash
# Verifier for "Generate a SLSA Provenance Attestation".
# Runs a hidden pytest harness against the learner's implementation.
# Prints flag only when all 7 tests pass.
set -uo pipefail

SLUG="06-provenance-attestation"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{provenance_pins_the_supply_chain}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory not found — run setup.sh first"
[ -f "$WORK/generate_attestation.py" ] || fail "generate_attestation.py not found — run setup.sh"
[ -f "$WORK/check_attestation.py" ] || fail "check_attestation.py not found — run setup.sh"
[ -f "$WORK/attestation.json" ] \
  || fail "attestation.json not found — run: python3 $WORK/generate_attestation.py"

# Find pytest
if [ -f "$WORK/.venv/bin/pytest" ]; then
  PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
  PYTEST=pytest
else
  fail "pytest not found — run: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

# Write the hidden test to a temporary directory
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

cat > "$TMPDIR_TEST/test_hidden.py" << 'PYEOF'
import json, hashlib, copy, sys
from pathlib import Path

WORK = Path.home() / ".kube-dojo-work" / "06-provenance-attestation"
sys.path.insert(0, str(WORK))

from generate_attestation import generate_attestation
from check_attestation import check_attestation


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def _make():
    return generate_attestation(WORK / "artifact.bin", WORK / "build_metadata.json")


def test_statement_type():
    att = _make()
    assert att.get("_type") == "https://in-toto.io/Statement/v0.1", \
        f"_type must be 'https://in-toto.io/Statement/v0.1', got {att.get('_type')!r}"


def test_predicate_type():
    att = _make()
    assert att.get("predicateType") == "https://slsa.dev/provenance/v0.2", \
        f"predicateType must be 'https://slsa.dev/provenance/v0.2', got {att.get('predicateType')!r}"


def test_subject_digest_matches_artifact():
    att = _make()
    expected = _sha256(WORK / "artifact.bin")
    subjects = att.get("subject", [])
    assert subjects, "subject array must not be empty"
    found = any(s.get("digest", {}).get("sha256") == expected for s in subjects)
    assert found, \
        f"no subject entry has sha256={expected!r} — compute the digest from the file, do not hard-code it"


def test_predicate_required_fields():
    pred = _make().get("predicate", {})
    assert pred.get("builder", {}).get("id"), "predicate.builder.id must be a non-empty string"
    assert pred.get("buildType"), "predicate.buildType must be non-empty"
    assert "invocation" in pred, "predicate.invocation is required"
    materials = pred.get("materials", [])
    assert isinstance(materials, list) and materials, "predicate.materials must be a non-empty list"


def test_verifier_accepts_good_attestation():
    att = _make()
    result = check_attestation(att, WORK / "artifact.bin")
    assert result is True, \
        "check_attestation(good_attestation, artifact.bin) must return True"


def test_verifier_rejects_mismatched_digest():
    bad = copy.deepcopy(_make())
    bad["subject"][0]["digest"]["sha256"] = "0" * 64
    result = check_attestation(bad, WORK / "artifact.bin")
    assert result is False, \
        "check_attestation must return False when subject digest does not match artifact"


def test_verifier_rejects_missing_builder():
    bad = copy.deepcopy(_make())
    bad["predicate"]["builder"]["id"] = ""
    result = check_attestation(bad, WORK / "artifact.bin")
    assert result is False, \
        "check_attestation must return False when predicate.builder.id is empty"
PYEOF

if $PYTEST "$TMPDIR_TEST/test_hidden.py" -q 2>&1; then
  echo
  echo "All 7 attestation checks passed. Submit this flag in the platform:"
  echo
  echo "    $FLAG"
else
  fail "test suite has failures — fix generate_attestation.py and check_attestation.py, then re-run"
fi
