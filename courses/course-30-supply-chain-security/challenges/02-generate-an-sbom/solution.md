# Solution — Generate an SBOM

## Complete `sbom_gen.py`

```python
import json
import os


def generate_sbom(packages: list) -> dict:
    components = []
    for pkg in packages:
        name    = pkg["name"]
        version = pkg["version"]
        components.append({
            "type":    "library",
            "name":    name,
            "version": version,
            "purl":    f"pkg:pypi/{name}@{version}",
        })
    return {
        "bomFormat":   "CycloneDX",
        "specVersion": "1.4",
        "version":     1,
        "components":  components,
    }


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
```

## Why each field is required

**`bomFormat: "CycloneDX"`** identifies the standard. CycloneDX and SPDX are the two dominant SBOM formats. Enterprise scanners and tools like OWASP Dependency-Track key off this field to pick a parser.

**`specVersion: "1.4"`** pins the schema version. CycloneDX 1.4 added vulnerability enrichment and dependencies graph support. Naming the version tells ingestion tools exactly which fields to expect.

**`version: 1`** is the revision counter for this specific SBOM document — useful when you re-generate a new SBOM for the same release (e.g., after backporting a patch).

**purl — Package URL.** The spec is at `https://github.com/package-url/purl-spec`. For PyPI: `pkg:pypi/<name>@<version>`. Tools cross-reference this against CVE databases; an SBOM without purls is basically useless for automated vulnerability scanning.

**`type: "library"`** is the CycloneDX component type for all third-party packages. Other types include `application`, `container`, and `firmware`.

## Generate and verify

```bash
cd ~/.kube-dojo-work/02-generate-an-sbom
python sbom_gen.py
# inspect the output:
cat sbom.json
bash courses/course-30-supply-chain-security/challenges/02-generate-an-sbom/verify.sh
```

## Attacker's view / hardening preview

An SBOM is only as useful as the pipeline it feeds. In a hardened supply chain:

1. The SBOM is generated in CI and published as a release artifact (pinned to the image digest).
2. A tool like OWASP Dependency-Track ingests it and alerts on newly-disclosed CVEs — even for already-released images.
3. The SBOM is signed alongside the image (cosign) so consumers can verify it hasn't been swapped.

Without the SBOM, step 2 is impossible: you can't scan for CVEs in components you haven't enumerated.

## Real tool equivalent

```bash
# syft on a local Python project directory
syft packages dir:. -o cyclonedx-json=sbom.json

# syft on a Docker image
syft packages ghcr.io/myorg/myapp:1.0.0 -o cyclonedx-json=sbom.json
```
