#!/usr/bin/env bash
# Plants the "Scan and Fix Vulnerabilities" scenario into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/03-scan-and-fix-vulns"
mkdir -p "$WORK/tests"

# ── requirements.txt (vulnerable initial state) ────────────────────────────────
cat > "$WORK/requirements.txt" << 'EOF'
requests==2.28.0
flask==3.0.0
click==8.1.7
werkzeug==3.0.1
certifi==2024.2.2
EOF

# ── advisories.json (mini advisory DB) ───────────────────────────────────────
cat > "$WORK/advisories.json" << 'EOF'
[
  {
    "id": "CVE-2023-32681",
    "package": "requests",
    "affected_versions": ["2.27.0", "2.27.1", "2.28.0", "2.28.1", "2.28.2", "2.29.0", "2.30.0"],
    "severity": "CRITICAL",
    "fixed_version": "2.31.0",
    "description": "Requests forwards proxy-authorization headers to the destination server when following a redirect to a different host. An attacker controlling a redirect target can harvest credentials passed via the Proxy-Authorization header."
  },
  {
    "id": "CVE-2024-35195",
    "package": "requests",
    "affected_versions": ["2.32.0", "2.32.1"],
    "severity": "MEDIUM",
    "fixed_version": "2.32.2",
    "description": "Requests fails to strip the Proxy-Authorization header on cross-scheme redirects when verify=False is set, potentially leaking credentials."
  },
  {
    "id": "CVE-2024-47081",
    "package": "urllib3",
    "affected_versions": ["2.2.1", "2.2.2"],
    "severity": "MEDIUM",
    "fixed_version": "2.3.0",
    "description": "urllib3 strips the Authorization header on cross-origin redirects when using a custom Host header. Not present in our deps — should NOT appear in results."
  }
]
EOF

# ── scanner.py stub ───────────────────────────────────────────────────────────
cat > "$WORK/scanner.py" << 'PYEOF'
# scanner.py
# Implement scan(). Do NOT change the signature.


def scan(deps: list, advisories: list) -> list:
    """
    deps: list of {"name": str, "version": str}
    advisories: list of {
        "id": str,
        "package": str,
        "affected_versions": list[str],
        "severity": str,
        "fixed_version": str,
        "description": str
    }

    For each (dep, advisory) pair where:
        dep["name"] == advisory["package"]
        AND dep["version"] in advisory["affected_versions"]

    append a finding dict to the results:
        {
            "dep":      <dep name>,
            "version":  <dep version>,
            "cve":      <advisory id>,
            "severity": <advisory severity>,
            "fix":      <advisory fixed_version>
        }

    Return the list of findings. Return [] if nothing matches.
    Iteration order: outer = deps, inner = advisories.
    """
    raise NotImplementedError
PYEOF

# ── visible sanity test ───────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_scanner.py" << 'PYEOF'
# Visible sanity harness — run: pytest tests/ -v
# The verifier runs a separate hidden suite; passing these is a good sign.
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from scanner import scan

ADV = [
    {
        "id": "CVE-2099-00001",
        "package": "alpha",
        "affected_versions": ["1.0.0", "1.0.1"],
        "severity": "CRITICAL",
        "fixed_version": "1.1.0",
        "description": "test advisory A",
    },
    {
        "id": "CVE-2099-00002",
        "package": "beta",
        "affected_versions": ["2.0.0"],
        "severity": "HIGH",
        "fixed_version": "2.1.0",
        "description": "test advisory B",
    },
]


def test_scan_detects_known_vuln():
    deps = [{"name": "alpha", "version": "1.0.0"}]
    findings = scan(deps, ADV)
    assert len(findings) == 1
    f = findings[0]
    assert f["cve"]      == "CVE-2099-00001"
    assert f["severity"] == "CRITICAL"
    assert f["fix"]      == "1.1.0"


def test_scan_no_false_positive_for_fixed_version():
    deps = [{"name": "alpha", "version": "1.1.0"}]
    findings = scan(deps, ADV)
    assert findings == [], f"1.1.0 is the fixed version — expected [], got {findings}"


def test_scan_clean_returns_empty():
    deps = [{"name": "gamma", "version": "9.9.9"}]
    findings = scan(deps, ADV)
    assert findings == []


def test_scan_no_cross_package_match():
    # alpha 1.0.0 should only match alpha advisories, not beta's
    deps = [{"name": "alpha", "version": "1.0.0"}, {"name": "beta", "version": "1.9.0"}]
    findings = scan(deps, ADV)
    assert all(f["dep"] == "alpha" for f in findings), \
        "beta at 1.9.0 (not in affected_versions) must not appear in findings"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Files planted  :"
echo "  requirements.txt  — five deps, one at a CRITICAL-vulnerable version"
echo "  advisories.json   — three advisory records (only one matches)"
echo "  scanner.py        — implement scan()"
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run sanity tests : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag    : bash courses/course-30-supply-chain-security/challenges/03-scan-and-fix-vulns/verify.sh"
