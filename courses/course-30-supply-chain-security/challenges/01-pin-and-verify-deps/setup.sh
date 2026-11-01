#!/usr/bin/env bash
# Plants the "Pin and Verify Dependencies" scenario into the work directory.
# Idempotent — re-running regenerates the lockfile and re-tampers the artifact.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/01-pin-and-verify-deps"
mkdir -p "$WORK/artifacts" "$WORK/tests"

# ── requirements.in ──────────────────────────────────────────────────────────
cat > "$WORK/requirements.in" << 'EOF'
# Direct runtime dependencies
requests==2.31.0
flask==3.0.0
click
EOF

# ── fake .whl artifacts ───────────────────────────────────────────────────────
# Write legitimate content for all three packages.
printf 'pkg-requests-2.31.0' > "$WORK/artifacts/requests-2.31.0.whl"
printf 'pkg-flask-3.0.0'     > "$WORK/artifacts/flask-3.0.0.whl"
printf 'pkg-click-8.1.7'     > "$WORK/artifacts/click-8.1.7.whl"

# Record sha256 of the LEGITIMATE content before tampering.
REQ_HASH=$(shasum -a 256   "$WORK/artifacts/requests-2.31.0.whl" | awk '{print $1}')
FLASK_HASH=$(shasum -a 256 "$WORK/artifacts/flask-3.0.0.whl"     | awk '{print $1}')
CLICK_HASH=$(shasum -a 256 "$WORK/artifacts/click-8.1.7.whl"     | awk '{print $1}')

# ── lockfile.json (correct hashes) ───────────────────────────────────────────
cat > "$WORK/lockfile.json" << JSONEOF
{
  "packages": [
    {"name": "requests", "version": "2.31.0", "sha256": "$REQ_HASH"},
    {"name": "flask",    "version": "3.0.0",  "sha256": "$FLASK_HASH"},
    {"name": "click",    "version": "8.1.7",  "sha256": "$CLICK_HASH"}
  ]
}
JSONEOF

# ── tamper flask AFTER hashing ───────────────────────────────────────────────
# The lockfile records the hash of 'pkg-flask-3.0.0'; we replace the file
# content so verify_hashes should flag flask as tampered.
printf 'pkg-flask-3.0.0-TAMPERED' > "$WORK/artifacts/flask-3.0.0.whl"

# ── checker.py stub ───────────────────────────────────────────────────────────
cat > "$WORK/checker.py" << 'PYEOF'
# checker.py
# Implement both functions. Do NOT change the signatures.
import hashlib
import re


def find_unpinned(requirements_text: str) -> list:
    """
    Parse requirements_text (contents of a requirements.in / requirements.txt).
    Return a list of package names that are NOT pinned with an exact == specifier.
    Ignore blank lines and lines that start with #.

    Examples:
        "requests==2.31.0\nflask\n" -> ["flask"]
        "click>=7.0\nurllib3\n"     -> ["click", "urllib3"]
        "requests==2.31.0\n"        -> []
    """
    raise NotImplementedError


def verify_hashes(lockfile: dict, artifacts_dir: str) -> list:
    """
    lockfile: dict with shape {"packages": [{"name": str, "version": str, "sha256": str}, ...]}
    artifacts_dir: path to a directory containing files named <name>-<version>.whl

    For each entry in lockfile["packages"]:
      1. Read the file artifacts_dir/<name>-<version>.whl as bytes.
      2. Compute its sha256 hex digest.
      3. Compare to the sha256 in the lockfile entry.

    Return a list of package names where the hash does NOT match (tampered or missing).
    """
    raise NotImplementedError
PYEOF

# ── visible sanity test ───────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_checker.py" << 'PYEOF'
# Visible sanity harness — run this to check your progress.
# The verifier runs a separate, stricter hidden suite.
import sys
import os
import hashlib

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from checker import find_unpinned, verify_hashes


def test_find_unpinned_detects_bare_name():
    result = find_unpinned("requests==2.31.0\nflask\n")
    assert "flask" in result, "bare 'flask' with no specifier must be flagged"
    assert "requests" not in result, "requests== must not be flagged"


def test_find_unpinned_ignores_comments_and_blanks():
    result = find_unpinned("# header comment\n\nrequests==2.31.0\n")
    assert result == [], f"expected [], got {result}"


def test_verify_hashes_detects_tamper(tmp_path):
    (tmp_path / "pkg-x-1.0.whl").write_bytes(b"content-x")
    (tmp_path / "pkg-y-1.0.whl").write_bytes(b"content-y-tampered")
    h_x = hashlib.sha256(b"content-x").hexdigest()
    h_y = hashlib.sha256(b"content-y-original").hexdigest()  # won't match tampered file
    lockfile = {
        "packages": [
            {"name": "pkg-x", "version": "1.0", "sha256": h_x},
            {"name": "pkg-y", "version": "1.0", "sha256": h_y},
        ]
    }
    result = verify_hashes(lockfile, str(tmp_path))
    assert "pkg-y" in result, "tampered pkg-y must be detected"
    assert "pkg-x" not in result, "clean pkg-x must not be flagged"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Files planted  :"
echo "  requirements.in   — three deps, one unpinned"
echo "  lockfile.json     — sha256 hashes (flask's artifact has been tampered)"
echo "  artifacts/        — fake .whl files"
echo "  checker.py        — implement find_unpinned() and verify_hashes()"
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run sanity tests : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag    : bash courses/course-30-supply-chain-security/challenges/01-pin-and-verify-deps/verify.sh"
