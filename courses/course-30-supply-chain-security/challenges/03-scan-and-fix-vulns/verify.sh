#!/usr/bin/env bash
# Verifier for "Scan and Fix Vulnerabilities".
# Runs a hidden pytest suite; prints the flag only when all checks pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/03-scan-and-fix-vulns"
FLAG='KUBE{scan_and_fix_the_supply_chain}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]                  || fail "work directory missing — run setup.sh first"
[ -f "$WORK/scanner.py" ]       || fail "scanner.py not found — run setup.sh first"
[ -f "$WORK/advisories.json" ]  || fail "advisories.json missing — run setup.sh first"
[ -f "$WORK/requirements.txt" ] || fail "requirements.txt missing — run setup.sh first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

TMPDIR_HIDDEN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_HIDDEN"' EXIT

cat > "$TMPDIR_HIDDEN/test_hidden_03.py" << 'PYEOF'
import sys
import os
import json
import re

WORK = os.environ.get("KUBE_DOJO_WORK", os.path.expanduser("~/.kube-dojo-work/03-scan-and-fix-vulns"))
sys.path.insert(0, WORK)

from scanner import scan

# ── advisory fixtures ────────────────────────────────────────────────────────

ADVISORIES_HIDDEN = [
    {
        "id": "CVE-2099-10001",
        "package": "libfoo",
        "affected_versions": ["0.9.0", "0.9.1", "1.0.0"],
        "severity": "CRITICAL",
        "fixed_version": "1.1.0",
        "description": "hidden test advisory for libfoo",
    },
    {
        "id": "CVE-2099-10002",
        "package": "libbar",
        "affected_versions": ["3.0.0"],
        "severity": "HIGH",
        "fixed_version": "3.1.0",
        "description": "hidden test advisory for libbar",
    },
    {
        "id": "CVE-2099-10003",
        "package": "libbaz",
        "affected_versions": ["5.5.5"],
        "severity": "MEDIUM",
        "fixed_version": "5.6.0",
        "description": "hidden test advisory for libbaz",
    },
]


def test_scan_detects_critical():
    deps = [{"name": "libfoo", "version": "1.0.0"}]
    findings = scan(deps, ADVISORIES_HIDDEN)
    assert len(findings) == 1, f"expected 1 finding, got {findings}"
    f = findings[0]
    assert f["dep"]      == "libfoo",          f"dep must be libfoo, got {f['dep']}"
    assert f["version"]  == "1.0.0",           f"version must be 1.0.0, got {f['version']}"
    assert f["cve"]      == "CVE-2099-10001",  f"cve must match, got {f['cve']}"
    assert f["severity"] == "CRITICAL",        f"severity must be CRITICAL, got {f['severity']}"
    assert f["fix"]      == "1.1.0",           f"fix must be 1.1.0, got {f['fix']}"


def test_scan_no_match_when_fixed():
    deps = [{"name": "libfoo", "version": "1.1.0"}]
    findings = scan(deps, ADVISORIES_HIDDEN)
    assert findings == [], f"fixed version 1.1.0 must return [], got {findings}"


def test_scan_no_false_positive_unrelated_package():
    deps = [{"name": "libqux", "version": "9.9.9"}]
    findings = scan(deps, ADVISORIES_HIDDEN)
    assert findings == [], f"unknown package must return [], got {findings}"


def test_scan_multiple_advisories_same_package():
    # libfoo at 0.9.0 matches CVE-2099-10001 (affected_versions includes 0.9.0)
    deps = [{"name": "libfoo", "version": "0.9.0"}]
    findings = scan(deps, ADVISORIES_HIDDEN)
    cves = [f["cve"] for f in findings]
    assert "CVE-2099-10001" in cves, "0.9.0 must be flagged by CVE-2099-10001"


def test_scan_multiple_deps_only_match_flagged():
    deps = [
        {"name": "libfoo", "version": "1.0.0"},   # vulnerable
        {"name": "libbar", "version": "2.9.0"},   # not in affected_versions
        {"name": "libbaz", "version": "5.6.0"},   # fixed version
    ]
    findings = scan(deps, ADVISORIES_HIDDEN)
    assert len(findings) == 1, f"only libfoo at 1.0.0 should be flagged, got {findings}"
    assert findings[0]["dep"] == "libfoo"


def test_scan_on_planted_advisories_detects_requests():
    adv_file = os.path.join(WORK, "advisories.json")
    with open(adv_file) as f:
        advisories = json.load(f)
    deps = [{"name": "requests", "version": "2.28.0"}]
    findings = scan(deps, advisories)
    assert any(f["dep"] == "requests" and f["severity"] == "CRITICAL" for f in findings), (
        "requests==2.28.0 must be flagged as CRITICAL against the planted advisories.json"
    )


def test_requirements_txt_is_clean():
    adv_file = os.path.join(WORK, "advisories.json")
    req_file = os.path.join(WORK, "requirements.txt")
    with open(adv_file) as f:
        advisories = json.load(f)
    # Parse requirements.txt: lines of the form name==version
    deps = []
    with open(req_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            m = re.match(r'^([A-Za-z0-9_.-]+)==(.+)$', line)
            if m:
                deps.append({"name": m.group(1), "version": m.group(2)})
    findings = scan(deps, advisories)
    assert findings == [], (
        f"requirements.txt still has vulnerable deps: {findings}\n"
        "Bump the vulnerable package to its fixed_version and save requirements.txt."
    )
PYEOF

cd "$WORK"
if KUBE_DOJO_WORK="$WORK" "$PYTEST" "$TMPDIR_HIDDEN/test_hidden_03.py" -q 2>&1; then
    echo
    echo "All checks passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "some checks failed — see output above; fix scanner.py and update requirements.txt"
fi
