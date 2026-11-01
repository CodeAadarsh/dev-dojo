#!/usr/bin/env bash
# Verifier for "Sign and Verify Artifacts with cosign".
# Checks: (1) real artifact verifies OK, (2) tampered artifact is rejected.
# Prints flag only when both pass.
set -uo pipefail

SLUG="04-sign-and-verify"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{tampered_artifacts_fail_verification}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory not found — run setup.sh first"

for f in cosign.pub artifact.bin artifact.sig artifact.tampered.bin; do
  [ -f "$WORK/$f" ] || fail "$f missing from $WORK — see the brief for required files"
done

command -v cosign >/dev/null 2>&1 \
  || fail "cosign not installed — see brief prerequisites"

echo "Checking cosign verify-blob on artifact.bin ..."
cosign verify-blob \
  --key "$WORK/cosign.pub" \
  --signature "$WORK/artifact.sig" \
  "$WORK/artifact.bin" >/dev/null 2>&1 \
  || fail "cosign verify-blob failed on artifact.bin — check your key and signature"

echo "Checking cosign verify-blob on artifact.tampered.bin (must FAIL) ..."
if cosign verify-blob \
     --key "$WORK/cosign.pub" \
     --signature "$WORK/artifact.sig" \
     "$WORK/artifact.tampered.bin" >/dev/null 2>&1; then
  fail "cosign accepted the tampered artifact — artifact.tampered.bin must differ from artifact.bin"
fi

echo
echo "Both checks passed:"
echo "  ✓ Real artifact   : signature verified OK"
echo "  ✓ Tampered copy   : correctly rejected"
echo
echo "Submit this flag in the platform:"
echo
echo "    $FLAG"
