# SBOMs

> **Module 03 · Course 30** — A Software Bill of Materials is a structured, machine-readable manifest of every component in a piece of software. If you can't enumerate what's running, you can't know when something is vulnerable. This module is about generating SBOMs, reading them fluently, and plugging them into vulnerability and license workflows.

---

## What is an SBOM?

An SBOM (Software Bill of Materials) is a formal, structured inventory of all software components — language packages, OS-level libraries, build tools, base image packages — that make up a deployable artifact, along with their versions, licenses, and provenance.

The food-label analogy is accurate and worth internalizing: the label tells you what's in it; a separate safety check (allergy analysis, vulnerability scan) tells you whether it's safe for you. You need both, but you need the label *first*. An SBOM is the prerequisite for any security claim about a container image.

Two use cases drive almost all SBOM consumption:

1. **Vulnerability matching.** Given an SBOM and a CVE database, you can answer "do I have anything affected by CVE-2024-XXXX?" without re-scanning the live container — including retroactively, for images already running in production.
2. **License compliance.** For software distributed to customers, you need to know whether any component is GPL-licensed (potentially copyleft-infectious) or carries a commercial restriction before you ship it.

US Executive Order 14028 (May 2021) mandated SBOMs for all software sold to federal agencies. That mandate drove the tooling investment dramatically — the ecosystem went from niche academic interest to production-grade in approximately 18 months.

---

## SPDX vs CycloneDX

Two standards dominate the space. They cover overlapping ground but with different primary strengths:

| Aspect | SPDX | CycloneDX |
|--------|------|-----------|
| Governing body | Linux Foundation | OWASP |
| Current versions | 2.3, 3.0 | 1.5, 1.6 |
| Serialization formats | Tag-value, JSON, XML, RDF | JSON, XML |
| Primary strength | License expression and legal metadata | Security metadata (VEX, attestations, vulnerability assertions) |
| Dependency graph | `DESCRIBES`, `CONTAINS`, `DEPENDS_ON` relationships | `components` list + `dependencies` tree |
| VEX support | SPDX 3.0 (limited) | First-class in CycloneDX 1.4+ |
| Tooling | `spdx-tools`, `sbom-tool` (Microsoft), `syft` | `syft`, `cdxgen`, `trivy`, `grype` |

In practice: pick SPDX when the primary consumer is a legal/license team; pick CycloneDX when the primary consumer is a security workflow (vulnerability scanner, VEX assertions, supply-chain attestation). Most pipelines today default to CycloneDX for the security focus. `syft` generates both formats from the same scan, so the choice is a flag, not a re-scan.

---

## Generating SBOMs with syft

[syft](https://github.com/anchore/syft) from Anchore is the most widely used open-source SBOM generator. It inspects a container image, directory, or OCI archive and emits a structured SBOM.

```bash
# Install (macOS)
brew install syft

# Scan a container image from a registry; emit CycloneDX JSON
syft python:3.12-slim -o cyclonedx-json > python-3.12-slim.sbom.json

# Scan a directory (your source tree — richer dep graph if lockfiles are present)
syft dir:. -o cyclonedx-json > app.sbom.json

# Scan an image from your local Docker daemon (avoids a registry pull)
syft docker:myapp:dev -o cyclonedx-json > myapp.sbom.json

# Scan and also emit SPDX JSON in the same run
syft python:3.12-slim -o cyclonedx-json=cdx.json -o spdx-json=spdx.json
```

syft identifies packages from:
- **OS package managers:** `dpkg` (Debian/Ubuntu), `rpm` (RHEL/CentOS), `apk` (Alpine)
- **Language runtime package managers:** `pip`/`site-packages`, `npm`/`node_modules`, `go.sum`, `Cargo.lock`, `Gemfile.lock`, Maven `.pom` files, Gradle metadata
- **Embedded manifests:** JAR `MANIFEST.MF`, `.egg-info`, `.dist-info`, Go binary build info (`go version -m`)

A `python:3.12-slim`-based image will list *both* the Debian packages from the base OS (libc6, libssl3, etc.) and the Python packages installed into `site-packages`. Both matter — a CVE in OpenSSL can be exploited through your Python app.

---

## What's inside a CycloneDX SBOM

A minimal CycloneDX 1.5 JSON SBOM:

```json
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "serialNumber": "urn:uuid:4a8b1e6c-2a3d-4f5e-b7c8-9d1a2b3c4e5f",
  "version": 1,
  "metadata": {
    "timestamp": "2024-08-15T10:30:00Z",
    "tools": [{ "vendor": "Anchore", "name": "syft", "version": "1.1.0" }],
    "component": {
      "type": "container",
      "name": "myapp",
      "version": "2.4.0",
      "purl": "pkg:oci/myapp@sha256:abc123..."
    }
  },
  "components": [
    {
      "type": "library",
      "name": "requests",
      "version": "2.31.0",
      "purl": "pkg:pypi/requests@2.31.0",
      "licenses": [{ "license": { "id": "Apache-2.0" } }],
      "hashes": [{ "alg": "SHA-256", "content": "3b3b..." }]
    },
    {
      "type": "library",
      "name": "certifi",
      "version": "2024.2.2",
      "purl": "pkg:pypi/certifi@2024.2.2",
      "licenses": [{ "license": { "id": "MPL-2.0" } }]
    }
  ],
  "dependencies": [
    {
      "ref": "pkg:pypi/requests@2.31.0",
      "dependsOn": [
        "pkg:pypi/certifi@2024.2.2",
        "pkg:pypi/charset-normalizer@3.2.0",
        "pkg:pypi/idna@3.4",
        "pkg:pypi/urllib3@2.0.7"
      ]
    }
  ]
}
```

Key fields to understand:

**`purl` (Package URL):** a standardized identifier `pkg:<ecosystem>/<name>@<version>`. This is what vulnerability databases key on — OSV, NVD, and Grype all match against PURLs. A `purl` like `pkg:pypi/requests@2.31.0` is unambiguous across all tools and databases. Without PURLs, matching a component to a CVE is a string-matching heuristic; with PURLs, it's a lookup.

**`licenses`:** SPDX license expression identifiers. `Apache-2.0` is permissive; `GPL-3.0-only` is copyleft; `AGPL-3.0-only` is copyleft with a network-use clause. Your legal team should have a policy on which are allowed.

**`dependencies`:** the directed acyclic graph. Available when syft finds a lockfile; not always reconstructable from installed package metadata alone. The `dependencies` section is what makes an SBOM a *bill of materials* rather than just a package list.

---

## Consuming SBOMs for vulnerability matching

[grype](https://github.com/anchore/grype) from Anchore accepts CycloneDX and SPDX SBOMs directly, decoupling the vulnerability scan from the container runtime:

```bash
# Install (macOS)
brew install grype

# Scan an SBOM (not the live image)
grype sbom:myapp.sbom.json

# Show only critical and high; fail if any found
grype sbom:myapp.sbom.json --fail-on high --output table

# Only show vulnerabilities with a fix available
grype sbom:myapp.sbom.json --only-fixed

# JSON output for scripted processing
grype sbom:myapp.sbom.json -o json > vulns.json
```

Scanning the SBOM rather than the live image has significant operational benefits:
- **Offline environments:** you can ship the SBOM to an air-gapped scanner.
- **Historical scanning:** the SBOM from a build three months ago can be scanned against today's CVE database to determine retroactive exposure — useful when a new Critical CVE drops and you need to answer "which already-deployed versions are affected?"
- **Speed:** no container pull required; SBOM scan is milliseconds.

### License compliance check

```bash
# Extract all license identifiers from a CycloneDX JSON SBOM
python3 -I - <<'EOF' < myapp.sbom.json
import sys, json
sbom = json.load(sys.stdin)
licenses = set()
for comp in sbom.get("components", []):
    for lic_entry in comp.get("licenses", []):
        lic = lic_entry.get("license", {})
        lid = lic.get("id") or lic.get("name", "")
        if lid:
            licenses.add(lid)
for l in sorted(licenses):
    print(l)
EOF
```

Watch for: `GPL-2.0-only`, `GPL-3.0-only`, `AGPL-3.0-only` (copyleft implications for distributed software), and `SSPL-1.0` (MongoDB's license — not OSI-approved, has server-side provisions).

---

## SBOM in the pipeline

A mature pipeline generates the SBOM at build time, attaches it to the image, and scans it at promotion time. The SBOM is an artifact, not just a report — it travels with the image:

```yaml
# .github/workflows/build.yml (excerpt)
- name: Build image
  run: docker build -t $IMAGE:${{ github.sha }} .

- name: Generate SBOM from source (richer — lockfile present)
  run: |
    syft dir:. -o cyclonedx-json > sbom.json

- name: Scan SBOM for vulnerabilities
  run: |
    grype sbom:sbom.json --fail-on critical --only-fixed

- name: Attach SBOM to image via cosign
  run: |
    cosign attach sbom --sbom sbom.json \
      $IMAGE@$(docker inspect --format='{{index .RepoDigests 0}}' $IMAGE:${{ github.sha }})
```

When the SBOM is attached via `cosign attach`, it becomes part of the image's OCI referrers tree and can be retrieved by anyone with pull access:

```bash
# Retrieve the SBOM for a specific digest
cosign download sbom myregistry.io/myapp@sha256:abc123

# Or inspect referrers directly
oras discover --platform linux/amd64 myregistry.io/myapp@sha256:abc123
```

This means an SRE responding to an incident can immediately enumerate what's in a specific running image digest — no rebuild, no `syft` re-scan required. The SBOM is a first-class operational artifact.

---

## Debugging SBOMs

### Symptom table

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| SBOM lists 50 packages but `pip list` inside the container returns 127 | Lockfile was deleted before syft scanned the final image layer; syft fell back to `site-packages` discovery, missing packages without clean `dist-info` | Generate SBOM from `syft dir:.` over the *source tree* before the build; or copy the lockfile to a known path and generate SBOM in a build stage before the `RUN rm requirements.txt` step |
| Component shows version `0.0.0` or `NOASSERTION` | Runtime-installed packages without `dist-info` version metadata; OS packages without version in the layer metadata | For language packages: install from lockfile so `dist-info` is complete; for OS packages: `apt-get install -y` with explicit pinned versions produces proper metadata |
| `grype sbom:...` finds 0 vulnerabilities on an image with clearly old packages | grype's local vulnerability DB is stale | `grype db update` then re-scan; check `grype db status` for last update time |
| Tool reports "unrecognized format" when ingesting the SBOM | SPDX tag-value format passed to a tool expecting SPDX JSON; or CycloneDX 1.6 passed to a tool only supporting 1.4 | Check with `head -5 sbom.json`; ensure both producer and consumer agree on format and spec version; use `-o spdx-json` not `-o spdx` for JSON output from syft |
| `dependencies` section is missing or empty in the SBOM | syft scanned installed files without access to a lockfile; dep relationships can't be inferred from installed packages alone | Scan the source directory (`syft dir:.`) rather than the final image; ensure lockfiles are present during the scan step |
| SBOM `metadata.component` has no version | syft couldn't infer the image version from available metadata | Pass version explicitly: `syft docker:myapp:1.0.0 --source-version 1.0.0 -o cyclonedx-json` |

> **War story.** A platform team I worked with generated SBOMs for every image in their pipeline and ran automated license checks against them. Compliance was clean for months. During an acquisition due-diligence review, a third-party auditor ran `grype` against the SBOM for the main API service and found 79 packages — but the security team's internal tooling reported 48. I compared them. The delta: the platform team generated their SBOMs using `syft docker:myapp:latest` (scanning the final image layer), and their Dockerfile included `RUN pip install -r requirements.txt && rm -rf /root/.cache/pip requirements.txt`. The `rm` happened in the same layer as the install, so the lockfile was never present when syft ran. syft fell back to `site-packages` discovery and silently missed 31 packages that didn't have complete `dist-info` metadata (several were installed via editable installs from private packages, others were pre-compiled wheels). The auditor's tool scanned the source tree before the Docker build and found the full set from the lockfile. The fix was reordering the CI step: `syft dir:.` before `docker build`, using the pre-build source tree. The SBOM was more accurate and took 3 seconds instead of 45.

---

## Checkpoint

You're ready when you can, without looking anything up:

1. Explain in one sentence what a PURL is and why it's the key field for vulnerability matching rather than just the package name and version.
2. Choose between SPDX and CycloneDX for a security-focused CI pipeline and give a two-sentence justification.
3. Run `syft` against a local Docker image and produce a CycloneDX JSON SBOM. Open the file and locate the `purl` for one Python package.
4. Feed that SBOM to `grype` and filter to Critical and High severity only. Note how many have a fix available.
5. Explain why an SBOM generated from `syft dir:.` over the source directory is more complete than one generated from `syft docker:<image>` after a multi-stage build.
6. Show the `cosign` command to attach an SBOM to an image and retrieve it later.
7. Write a 10-line Python snippet that reads a CycloneDX JSON SBOM from stdin and prints all components whose license contains `GPL`.
8. Describe the "historical scanning" use case for SBOMs — what problem does it solve that re-scanning the live image cannot?

➡ Next up: **Vulnerability Scanning** — trivy, grype, CVE/CVSS triage, false positive management, failing the build on criticals, and VEX assertions.
