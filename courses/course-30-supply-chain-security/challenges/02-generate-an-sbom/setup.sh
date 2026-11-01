#!/usr/bin/env bash
# Plants the "Generate an SBOM" scenario into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/02-generate-an-sbom"
mkdir -p "$WORK/tests"

# ── requirements.txt ──────────────────────────────────────────────────────────
cat > "$WORK/requirements.txt" << 'EOF'
requests==2.31.0
flask==3.0.0
click==8.1.7
werkzeug==3.0.1
EOF

# ── packages.json (parsed input for sbom_gen.py) ─────────────────────────────
cat > "$WORK/packages.json" << 'EOF'
[
  {"name": "requests",  "version": "2.31.0"},
  {"name": "flask",     "version": "3.0.0"},
  {"name": "click",     "version": "8.1.7"},
  {"name": "werkzeug",  "version": "3.0.1"}
]
EOF

# ── sbom_gen.py stub ──────────────────────────────────────────────────────────
cat > "$WORK/sbom_gen.py" << 'PYEOF'
# sbom_gen.py
# Implement generate_sbom(). The __main__ block is already wired — just run:
#   python sbom_gen.py
# to produce sbom.json in this directory once your function works.
import json
import os


def generate_sbom(packages: list) -> dict:
    """
    packages: list of {"name": str, "version": str}

    Return a CycloneDX 1.4 SBOM as a dict:
    {
        "bomFormat": "CycloneDX",
        "specVersion": "1.4",
        "version": 1,
        "components": [
            {
                "type": "library",
                "name": <name>,
                "version": <version>,
                "purl": "pkg:pypi/<name>@<version>"
            },
            ...
        ]
    }
    The purl format for PyPI: pkg:pypi/<name>@<version>  (lowercase name, no spaces).
    """
    raise NotImplementedError


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "packages.json")) as f:
        packages = json.load(f)
    sbom = generate_sbom(packages)
    out = os.path.join(here, "sbom.json")
    with open(out, "w") as f:
        json.dump(sbom, f, indent=2)
    print(f"SBOM written to {out}")
    print(f"  {len(sbom.get('components', []))} component(s) listed")
PYEOF

# ── visible sanity test ───────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sbom_gen.py" << 'PYEOF'
# Visible sanity harness — run: pytest tests/ -v
# The verifier runs a stricter hidden suite with different package data.
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from sbom_gen import generate_sbom


PACKAGES = [
    {"name": "requests", "version": "2.31.0"},
    {"name": "flask",    "version": "3.0.0"},
]


def test_top_level_fields():
    sbom = generate_sbom(PACKAGES)
    assert sbom.get("bomFormat")   == "CycloneDX"
    assert sbom.get("specVersion") == "1.4"
    assert sbom.get("version")     == 1


def test_component_count():
    sbom = generate_sbom(PACKAGES)
    assert len(sbom["components"]) == len(PACKAGES)


def test_purl_format():
    sbom = generate_sbom(PACKAGES)
    for comp in sbom["components"]:
        assert comp["purl"] == f"pkg:pypi/{comp['name']}@{comp['version']}", \
            f"purl must be pkg:pypi/<name>@<version>, got {comp['purl']}"


def test_component_has_required_fields():
    sbom = generate_sbom(PACKAGES)
    for comp in sbom["components"]:
        for field in ("type", "name", "version", "purl"):
            assert field in comp, f"component missing field '{field}'"
        assert comp["type"] == "library"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Files planted  :"
echo "  requirements.txt — four pinned deps (the component source)"
echo "  packages.json    — parsed list ready for sbom_gen.py"
echo "  sbom_gen.py      — implement generate_sbom(), then run the script"
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run sanity tests : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Generate SBOM    : cd $WORK && .venv/bin/python sbom_gen.py"
echo "Verify + flag    : bash courses/course-30-supply-chain-security/challenges/02-generate-an-sbom/verify.sh"
