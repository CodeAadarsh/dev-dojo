# Supply Chain Inject — Solution

## Step 1: Read Both SBOMs

```bash
echo "=== SBOM v1.2.3 (clean) ==="
kubectl get configmap sbom-v1-2-3 -n dojo-sec-supply -o jsonpath='{.data}' | tr ',' '\n'

echo ""
echo "=== SBOM v1.2.4 (tampered) ==="
kubectl get configmap sbom-v1-2-4 -n dojo-sec-supply -o jsonpath='{.data}' | tr ',' '\n'
```

## Step 2: Find the Difference

v1.2.3 packages: alpine, curl, libssl3, ca-certificates, nodejs, npm, python3, musl

v1.2.4 packages: alpine, curl, libssl3, ca-certificates, nodejs, npm, python3, musl, **audit-logger-1.2.3**

The injected package: `audit-logger-1.2.3`

## Step 3: Read the Flag

```bash
kubectl get configmap sbom-v1-2-4 -n dojo-sec-supply \
  -o jsonpath='{.data.audit-logger-1\.2\.3}'
```

(Note: dots in the key must be escaped as `\.` in jsonpath)

**Flag: `KUBE{sbom_diff_reveals_injected_package}`**

---

## Why This Matters

The package `audit-logger-1.2.3` wasn't in the base image and wasn't explicitly installed in the Dockerfile. It was injected — most likely:
1. The base image was tampered (a "typosquatting" attack on the registry)
2. The build pipeline itself was compromised (a CI script ran `npm install evil-package`)
3. A developer's machine was compromised and pushed a tampered layer

**The defense:**
- Generate and store SBOMs for every image at build time (via `syft`)
- Compare SBOMs between builds in CI — alert on new packages not in the allow-list
- Sign images with cosign and require signatures on deploy (Kyverno verifyImages)
- Use digest-pinned base images (`FROM alpine@sha256:...` not `FROM alpine:3.19`)

```bash
# Real SBOM generation in CI:
syft company/webapp:v1.2.4 -o cyclonedx-json > sbom-v1.2.4.json
# Then diff against previous:
diff sbom-v1.2.3.json sbom-v1.2.4.json
```
