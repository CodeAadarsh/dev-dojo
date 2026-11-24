# Solution — Supply Chain Inject

## The Attack

A malicious package `lodash-dev-proxy@1.0.0` was injected into the app's dependency tree between builds. This is a **dependency confusion** or **package injection** attack — the package name looks like a legitimate lodash utility but is controlled by the attacker.

## Step 1 — Generate SBOMs

```bash
# Install syft if needed: brew install syft
syft dojo/app-clean:1.0 -o spdx-json > clean.json
syft dojo/app-infected:1.1 -o spdx-json > infected.json
```

SPDX (Software Package Data Exchange) is an open standard for SBOMs. Each SBOM lists every package, version, and license in the image.

## Step 2 — Diff the package lists

Using POSIX tools (no jq required):

```bash
# Extract package names from each SBOM
grep '"name"' clean.json | sort -u > clean-names.txt
grep '"name"' infected.json | sort -u > infected-names.txt

# Find packages in infected but NOT in clean
comm -13 clean-names.txt infected-names.txt
```

Or with syft's built-in diff:
```bash
syft packages dojo/app-infected:1.1 | grep -v -F -f <(syft packages dojo/app-clean:1.0 | awk '{print $1}')
```

The injected package: **`lodash-dev-proxy`**

## Step 3 — Record the finding

```bash
kubectl create configmap sbom-diff-result \
  -n dojo-sec-supplychain \
  --from-literal=malicious_package=lodash-dev-proxy
```

## Step 4 — Fix the deployment

```bash
kubectl set image deployment/app web=dojo/app-clean:1.0 -n dojo-sec-supplychain
kubectl rollout status deployment/app -n dojo-sec-supplychain
```

## Step 5 — Mark remediated

```bash
kubectl annotate namespace dojo-sec-supplychain dojo.supply-chain/status=remediated --overwrite
```

**Flag:** `KUBE{sbom_diff_reveals_injected_package}`

## How This Attack Happens in Practice

**Dependency confusion**: An attacker registers a public npm/PyPI/Maven package with the same name as an internal package. The build system resolves to the public (malicious) one.

**Typosquatting**: `lodash-dev-proxy` vs `lodash` — close enough to miss in a code review.

**Compromised registry**: The attacker gains write access to an internal registry (via stolen CI credentials) and replaces a package.

**CI pipeline injection** (covered in challenge 05): An attacker modifies the GitHub Actions workflow to `npm install <malicious-package>` during build.

## Prevention

**SBOM generation in CI** (GitHub Actions):
```yaml
- name: Generate SBOM
  uses: anchore/sbom-action@v0
  with:
    image: ${{ env.IMAGE }}
    format: spdx-json
    output-file: sbom.json

- name: Scan SBOM for vulnerabilities
  uses: anchore/scan-action@v3
  with:
    sbom: sbom.json
    fail-build: true
    severity-cutoff: high
```

**Package lock files**: Always commit `package-lock.json` / `Pipfile.lock` / `go.sum`. Reproducible builds prevent silent updates.

**Private registry with allowlist**: Only allow packages from an internal registry that mirrors approved public packages. Block direct internet access from CI runners.

**Admission control**: Require signed images (cosign/Sigstore). If CI is the only entity that signs images, an injection that bypasses CI can't produce a valid signature.

**Automated diff in CI**:
```bash
# Compare SBOM against previous known-good build
syft dojo/app-new:latest -o spdx-json > new.json
grype --only-fixed sbom:new.json
# Also diff against baseline:
# bomutils diff baseline.json new.json | jq '.added[]'
```
