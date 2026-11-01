# Solution — Scan and Fix Vulnerabilities

## Complete `scanner.py`

```python
def scan(deps: list, advisories: list) -> list:
    findings = []
    for dep in deps:
        for adv in advisories:
            if dep["name"] == adv["package"] and dep["version"] in adv["affected_versions"]:
                findings.append({
                    "dep":      dep["name"],
                    "version":  dep["version"],
                    "cve":      adv["id"],
                    "severity": adv["severity"],
                    "fix":      adv["fixed_version"],
                })
    return findings
```

## Fix `requirements.txt`

Run your scanner first to identify the vulnerable dep:

```python
import json
from scanner import scan

with open("requirements.txt") as f:
    deps = []
    for line in f:
        line = line.strip()
        if line and not line.startswith('#') and '==' in line:
            name, version = line.split('==', 1)
            deps.append({"name": name, "version": version})

with open("advisories.json") as f:
    advisories = json.load(f)

print(scan(deps, advisories))
```

Output:
```
[{'dep': 'requests', 'version': '2.28.0', 'cve': 'CVE-2023-32681', 'severity': 'CRITICAL', 'fix': '2.31.0'}]
```

Edit `requirements.txt`: change `requests==2.28.0` → `requests==2.31.0`.

After the fix:

```
requests==2.31.0
flask==3.0.0
click==8.1.7
werkzeug==3.0.1
certifi==2024.2.2
```

Run again → `[]`.

## Why each piece is correct

**The nested loop: outer = deps, inner = advisories.**  
This mirrors how real scanners work: for every component in your manifest, check it against every entry in the vulnerability database. The database can have millions of records in production (NVD + OSV); tools like trivy use an indexed local copy for speed, but the matching logic is identical.

**Name + version must both match.**  
Matching only on name would flag every version of a package — a false positive explosion. Matching only on version is meaningless. Both conditions must be true simultaneously. Some scanners also support version range expressions (e.g., `< 2.31.0`) rather than explicit version lists; the explicit-list model here is simpler but functionally equivalent for this advisory format.

**CVE-2023-32681 — what it actually is.**  
This is a real CVE. Requests followed HTTP 301 and 302 redirects from an HTTPS URL to an HTTP URL while keeping the `Proxy-Authorization` header in the request — handing credentials to whatever server the attacker-controlled redirect pointed at. The fix in 2.31.0 strips auth headers on cross-scheme redirects. The reason Dependabot flagged it as CRITICAL: any service that sets `proxies={"https": "..."}` with credentials was silently leaking them on redirect.

## Attacker's view

If you ship with `requests==2.28.0` and an attacker can make your service follow a redirect to an HTTP endpoint they control (e.g., by compromising a third-party API's DNS), they get your proxy credentials for free. No exploit code required — just a crafted 301 response.

## Real tools

```bash
# trivy on the current directory (reads requirements.txt, Pipfile, etc.)
trivy fs . --severity CRITICAL,HIGH

# grype on a local directory
grype dir:.

# grype on a Docker image
grype myapp:1.0.0
```

Both tools generate a finding list identical in shape to what `scan` returns: package name, installed version, CVE ID, severity, and fixed version.

## Apply and verify

```bash
cd ~/.kube-dojo-work/03-scan-and-fix-vulns
.venv/bin/pytest tests/ -v
bash courses/course-30-supply-chain-security/challenges/03-scan-and-fix-vulns/verify.sh
```
