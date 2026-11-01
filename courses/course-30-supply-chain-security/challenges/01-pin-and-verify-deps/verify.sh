#!/usr/bin/env bash
# Verifier for "Pin and Verify Dependencies".
# Runs a hidden pytest suite; prints the flag only when all checks pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/01-pin-and-verify-deps"
FLAG='KUBE{pin_and_verify_dependencies}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]          || fail "work directory missing — run setup.sh first"
[ -f "$WORK/checker.py" ] || fail "checker.py not found in $WORK — run setup.sh first"
[ -f "$WORK/lockfile.json" ] || fail "lockfile.json missing — run setup.sh first"
[ -d "$WORK/artifacts" ] || fail "artifacts/ directory missing — run setup.sh first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

TMPDIR_HIDDEN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_HIDDEN"' EXIT

cat > "$TMPDIR_HIDDEN/test_hidden_01.py" << 'PYEOF'
import sys
import os
import hashlib
import tempfile
import pathlib

WORK = os.environ.get("KUBE_DOJO_WORK", os.path.expanduser("~/.kube-dojo-work/01-pin-and-verify-deps"))
sys.path.insert(0, WORK)

from checker import find_unpinned, verify_hashes


def test_find_unpinned_bare_name():
    result = find_unpinned("requests==2.31.0\nflask==3.0.0\nclick\n")
    assert "click" in result, "bare 'click' must be detected as unpinned"
    assert "requests" not in result, "requests== must not be flagged"
    assert "flask" not in result, "flask== must not be flagged"


def test_find_unpinned_range_specifier():
    result = find_unpinned("urllib3>=1.26\nidna==3.4\n")
    assert "urllib3" in result, "urllib3>= (range) must be detected as unpinned"
    assert "idna" not in result, "idna== must not be flagged"


def test_find_unpinned_skips_comments_and_blanks():
    result = find_unpinned("# just a comment\n\nrequests==2.31.0\n# another\n\n")
    assert result == [], f"only comments and pins — expected [], got {result}"


def test_find_unpinned_mixed_specifiers():
    text = "a==1.0\nb~=2.0\nc\nd!=3.0\ne==5.0\n"
    result = find_unpinned(text)
    for unpinned in ("b", "c", "d"):
        assert unpinned in result, f"'{unpinned}' should be flagged as unpinned"
    for pinned in ("a", "e"):
        assert pinned not in result, f"'{pinned}' has == and must not be flagged"


def test_verify_hashes_detects_tamper(tmp_path):
    (tmp_path / "requests-2.31.0.whl").write_bytes(b"pkg-requests-2.31.0")
    (tmp_path / "flask-3.0.0.whl").write_bytes(b"pkg-flask-3.0.0-TAMPERED")
    (tmp_path / "click-8.1.7.whl").write_bytes(b"pkg-click-8.1.7")
    h_req   = hashlib.sha256(b"pkg-requests-2.31.0").hexdigest()
    h_flask = hashlib.sha256(b"pkg-flask-3.0.0").hexdigest()     # correct hash; file is tampered
    h_click = hashlib.sha256(b"pkg-click-8.1.7").hexdigest()
    lockfile = {
        "packages": [
            {"name": "requests", "version": "2.31.0", "sha256": h_req},
            {"name": "flask",    "version": "3.0.0",  "sha256": h_flask},
            {"name": "click",    "version": "8.1.7",  "sha256": h_click},
        ]
    }
    result = verify_hashes(lockfile, str(tmp_path))
    assert "flask" in result, "tampered flask must be detected"
    assert "requests" not in result, "clean requests must not be flagged"
    assert "click" not in result, "clean click must not be flagged"


def test_verify_hashes_all_clean(tmp_path):
    (tmp_path / "alpha-0.1.whl").write_bytes(b"bytes-alpha")
    h = hashlib.sha256(b"bytes-alpha").hexdigest()
    lockfile = {"packages": [{"name": "alpha", "version": "0.1", "sha256": h}]}
    result = verify_hashes(lockfile, str(tmp_path))
    assert result == [], f"all-clean lockfile must return [], got {result}"


def test_requirements_fully_pinned():
    req_file = os.path.join(WORK, "requirements.in")
    with open(req_file) as f:
        text = f.read()
    unpinned = find_unpinned(text)
    assert unpinned == [], (
        f"requirements.in still has unpinned deps: {unpinned}\n"
        "Edit requirements.in and add a ==version pin for each flagged package."
    )
PYEOF

cd "$WORK"
if KUBE_DOJO_WORK="$WORK" "$PYTEST" "$TMPDIR_HIDDEN/test_hidden_01.py" -q 2>&1; then
    echo
    echo "All checks passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "some checks failed — see output above and fix checker.py / requirements.in"
fi
