# Generate an SBOM

Your compliance team just received a request: *"Before we can ship this service to the enterprise tier, we need a Software Bill of Materials in CycloneDX format so the customer's security scanner can ingest it."*

A Software Bill of Materials (SBOM) is a machine-readable inventory of every software component in a build. It answers "what's in the box?" — which is the first question any vulnerability scanner, license auditor, or compliance tool asks. In the real world you'd run `syft` and get one in seconds. Here you'll implement the generator by hand so you understand exactly what the format contains and why.

## Context

`setup.sh` plants a work directory:

```
~/.kube-dojo-work/02-generate-an-sbom/
├── requirements.txt     # pinned dependency list (the component source)
├── packages.json        # parsed list: [{"name": ..., "version": ...}, ...]
├── sbom_gen.py          # your implementation target + a __main__ runner
└── tests/
    └── test_sbom_gen.py # visible sanity harness
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/02-generate-an-sbom
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Open `sbom_gen.py` and implement `generate_sbom(packages: list) -> dict`.

The function receives a list of `{"name": str, "version": str}` dicts and must return a CycloneDX 1.4 SBOM:

```json
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.4",
  "version": 1,
  "components": [
    {
      "type": "library",
      "name": "requests",
      "version": "2.31.0",
      "purl": "pkg:pypi/requests@2.31.0"
    }
  ]
}
```

The **purl** (Package URL) format for PyPI packages is `pkg:pypi/<name>@<version>`. It's a universal, unambiguous identifier used by every supply-chain tool to cross-reference packages across databases.

Once `generate_sbom` works, run the script to produce `sbom.json`:

```bash
python sbom_gen.py
```

## What the verifier checks

| Check | What it tests |
|-------|---------------|
| Top-level fields | `bomFormat`, `specVersion`, `version` are present and correct |
| Component count | components list contains exactly the expected packages |
| purl format | every component has `purl` matching `pkg:pypi/<name>@<version>` |
| Component fields | every component has `type`, `name`, `version`, `purl` |
| `sbom.json` on disk | the file exists in your work dir and is valid JSON with the correct structure |

## Verify

```bash
bash courses/course-30-supply-chain-security/challenges/02-generate-an-sbom/verify.sh
```

## Real-world tool

`syft packages dir:. -o cyclonedx-json` produces the same CycloneDX JSON from any directory. The format you implement here is exactly what syft generates, minus the metadata block and hashes. Once you understand the shape, reading a syft SBOM in CI is trivial.
