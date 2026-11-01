#!/usr/bin/env bash
# Verifier for "Generate an SBOM".
# Runs a hidden pytest suite; prints the flag only when all checks pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/02-generate-an-sbom"
FLAG='KUBE{sbom_every_artifact}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]                || fail "work directory missing — run setup.sh first"
[ -f "$WORK/sbom_gen.py" ]    || fail "sbom_gen.py not found — run setup.sh first"
[ -f "$WORK/packages.json" ]  || fail "packages.json missing — run setup.sh first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

TMPDIR_HIDDEN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_HIDDEN"' EXIT

cat > "$TMPDIR_HIDDEN/test_hidden_02.py" << 'PYEOF'
import sys
import os
import json

WORK = os.environ.get("KUBE_DOJO_WORK", os.path.expanduser("~/.kube-dojo-work/02-generate-an-sbom"))
sys.path.insert(0, WORK)

from sbom_gen import generate_sbom

PKGS = [
    {"name": "certifi",  "version": "2024.2.2"},
    {"name": "charset-normalizer", "version": "3.3.2"},
    {"name": "idna",     "version": "3.6"},
]


def test_top_level_fields():
    sbom = generate_sbom(PKGS)
    assert sbom.get("bomFormat")   == "CycloneDX",  f"bomFormat must be 'CycloneDX', got {sbom.get('bomFormat')}"
    assert sbom.get("specVersion") == "1.4",         f"specVersion must be '1.4', got {sbom.get('specVersion')}"
    assert sbom.get("version")     == 1,             f"version must be integer 1, got {sbom.get('version')}"


def test_component_count():
    sbom = generate_sbom(PKGS)
    assert "components" in sbom, "SBOM must have a 'components' key"
    assert len(sbom["components"]) == len(PKGS), (
        f"expected {len(PKGS)} components, got {len(sbom['components'])}"
    )


def test_component_required_fields():
    sbom = generate_sbom(PKGS)
    for comp in sbom["components"]:
        for field in ("type", "name", "version", "purl"):
            assert field in comp, f"component {comp.get('name')} missing field '{field}'"
        assert comp["type"] == "library", f"type must be 'library', got {comp['type']}"


def test_purl_format():
    sbom = generate_sbom(PKGS)
    for comp in sbom["components"]:
        expected_purl = f"pkg:pypi/{comp['name']}@{comp['version']}"
        assert comp["purl"] == expected_purl, (
            f"purl for {comp['name']} must be '{expected_purl}', got '{comp['purl']}'"
        )


def test_names_and_versions_match_input():
    sbom = generate_sbom(PKGS)
    by_name = {c["name"]: c for c in sbom["components"]}
    for pkg in PKGS:
        assert pkg["name"] in by_name, f"component '{pkg['name']}' missing from SBOM"
        assert by_name[pkg["name"]]["version"] == pkg["version"], (
            f"version mismatch for {pkg['name']}: "
            f"expected {pkg['version']}, got {by_name[pkg['name']]['version']}"
        )


def test_sbom_file_exists_and_valid():
    sbom_path = os.path.join(WORK, "sbom.json")
    assert os.path.exists(sbom_path), (
        f"sbom.json not found at {sbom_path}\n"
        "Run: cd ~/.kube-dojo-work/02-generate-an-sbom && python sbom_gen.py"
    )
    with open(sbom_path) as f:
        sbom = json.load(f)
    assert sbom.get("bomFormat") == "CycloneDX", "sbom.json must have bomFormat=CycloneDX"
    assert "components" in sbom,                  "sbom.json must have a components list"
    assert len(sbom["components"]) == 4,           (
        f"sbom.json must list 4 components (from packages.json), got {len(sbom['components'])}"
    )
PYEOF

cd "$WORK"
if KUBE_DOJO_WORK="$WORK" "$PYTEST" "$TMPDIR_HIDDEN/test_hidden_02.py" -q 2>&1; then
    echo
    echo "All checks passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "some checks failed — see output above and fix sbom_gen.py, then run 'python sbom_gen.py'"
fi
