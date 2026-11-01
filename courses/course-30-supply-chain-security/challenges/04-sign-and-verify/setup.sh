#!/usr/bin/env bash
# Plants the "Sign and Verify Artifacts with cosign" scenario.
# Idempotent — safe to re-run.
set -euo pipefail

SLUG="04-sign-and-verify"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

# ── Artifact: a realistic-looking build manifest ────────────────────────────
printf '%s\n%s\n%s\n%s\n' \
  'build-output: dojo-hello-go-v1.4.2' \
  'commit: 7f3c2a8e1b5d9f0a4c6e8b2d4f1a3e6c' \
  'built-by: github-actions/2.320.0' \
  'timestamp: 2026-11-01T06:12:34Z' \
  > "$WORK/artifact.bin"

# ── Tampered copy: one character changed in the version string ───────────────
printf '%s\n%s\n%s\n%s\n' \
  'build-output: dojo-hello-go-v1.4.X' \
  'commit: 7f3c2a8e1b5d9f0a4c6e8b2d4f1a3e6c' \
  'built-by: github-actions/2.320.0' \
  'timestamp: 2026-11-01T06:12:34Z' \
  > "$WORK/artifact.tampered.bin"

echo
echo "Work directory : $WORK"
echo
echo "Files planted:"
echo "  artifact.bin          — the build output to sign"
echo "  artifact.tampered.bin — a modified copy; verification must reject it"
echo
echo "Next steps:"
echo "  1. cd $WORK"
echo "  2. Generate a cosign key pair:"
echo "       cosign generate-key-pair"
echo "  3. Sign artifact.bin:"
echo "       cosign sign-blob --key cosign.key artifact.bin > artifact.sig"
echo "  4. Verify the real artifact (expect: Verified OK):"
echo "       cosign verify-blob --key cosign.pub --signature artifact.sig artifact.bin"
echo "  5. Verify the tampered copy (expect: failure / non-zero exit):"
echo "       cosign verify-blob --key cosign.pub --signature artifact.sig artifact.tampered.bin"
echo "  6. Run the verifier:"
echo "       bash courses/course-30-supply-chain-security/challenges/04-sign-and-verify/verify.sh"
