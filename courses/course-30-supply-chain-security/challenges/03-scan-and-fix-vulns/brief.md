# Scan and Fix Vulnerabilities

Dependabot opened a PR with the title: *"[Security] bump requests from 2.28.0 to 2.31.0 — CVE-2023-32681 CRITICAL"*. The lead architect asks: *"Before we merge a dependency bump blindly, can we write a scanner so we actually understand what we're fixing and can automate this check in CI?"*

That's the challenge. In production you'd reach for `trivy` or `grype`. Here you'll implement the core matching logic so you know exactly what those tools do under the hood.

## Context

`setup.sh` plants a work directory:

```
~/.kube-dojo-work/03-scan-and-fix-vulns/
├── requirements.txt     # pinned deps — one is at a KNOWN-vulnerable version
├── advisories.json      # mini advisory database (subset of a real CVE feed)
├── scanner.py           # your implementation target
└── tests/
    └── test_scanner.py  # visible sanity harness
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/03-scan-and-fix-vulns
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

### Part 1 — implement `scan`

Open `scanner.py` and implement:

```python
def scan(deps: list, advisories: list) -> list
```

`deps`: list of `{"name": str, "version": str}` — your pinned dependency set.

`advisories`: list of advisory records:

```json
{
  "id": "CVE-2023-32681",
  "package": "requests",
  "affected_versions": ["2.28.0", "2.28.1", "2.28.2", "2.29.0", "2.30.0"],
  "severity": "CRITICAL",
  "fixed_version": "2.31.0",
  "description": "..."
}
```

Return a list of findings — one per matching (dep, advisory) pair:

```json
[
  {
    "dep": "requests",
    "version": "2.28.0",
    "cve": "CVE-2023-32681",
    "severity": "CRITICAL",
    "fix": "2.31.0"
  }
]
```

A dep matches an advisory when `dep["name"] == advisory["package"]` AND `dep["version"]` is in `advisory["affected_versions"]`. Return `[]` if nothing matches.

### Part 2 — fix `requirements.txt`

Run `scan` on the planted `requirements.txt`. Identify the vulnerable dep. Edit `requirements.txt` to bump it to the `fixed_version` from the advisory. Re-run `scan` — it should now return `[]`.

## What the verifier checks

| Check | What it tests |
|-------|---------------|
| `scan` unit tests (synthetic data) | correct match on name+version; no false positives; empty on clean set |
| `scan` on the CRITICAL advisory | flags the known-vulnerable dep with the right CVE and severity |
| `scan` with fixed version | returns `[]` when the dep is at the fixed version |
| `requirements.txt` state | running `scan` against the actual file now returns `[]` |

## Verify

```bash
bash courses/course-30-supply-chain-security/challenges/03-scan-and-fix-vulns/verify.sh
```

## Real-world tools

`trivy fs .` and `grype dir:.` both do exactly this: load a vulnerability database (OSV, NVD), parse your dependency manifest, and match. The advisory format used here mirrors the OSV (Open Source Vulnerabilities) schema that both tools consume.
