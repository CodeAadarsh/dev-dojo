# Supply Chain Inject — SBOM Diff Reveals Injected Package

Your team runs a container image build pipeline. Last week's build produced image `v1.2.3`. This week's build produced `v1.2.4`. The only change in the Dockerfile was a base image bump.

But when you diff the SBOMs (Software Bill of Materials), you find an extra package that wasn't in the previous build — and it wasn't in the base image either. Something was injected.

This challenge stores two SBOMs as ConfigMaps. Find the injected package, then use its name to retrieve the flag.

## What Is an SBOM?

An SBOM is a machine-readable list of every software component in an artifact:
- Package name + version
- License
- Source URL
- Hash

Tools like `syft` generate SBOMs for container images. When you have SBOMs for two versions of an image, you can diff them to find what changed.

## Mission

1. Read the two SBOM ConfigMaps in `dojo-sec-supply` namespace:
   - `sbom-v1-2-3` — the clean build
   - `sbom-v1-2-4` — the tampered build
2. Find the package that exists in v1.2.4 but NOT in v1.2.3
3. The flag is the value associated with the injected package name in `sbom-v1-2-4`

## Commands

```bash
# Read both SBOMs
kubectl get configmap sbom-v1-2-3 -n dojo-sec-supply -o jsonpath='{.data}' 
kubectl get configmap sbom-v1-2-4 -n dojo-sec-supply -o jsonpath='{.data}'

# The injected package name is a KEY in the sbom-v1-2-4 ConfigMap
# that does NOT exist in sbom-v1-2-3
# kubectl get configmap sbom-v1-2-4 -n dojo-sec-supply -o jsonpath='{.data.<package-name>}'
```

## Rules of Engagement

- Namespace: `dojo-sec-supply`
- SBOMs: ConfigMaps `sbom-v1-2-3` and `sbom-v1-2-4`
- Flag is a value in the tampered SBOM, keyed by the injected package name
- No verify.sh — discovery challenge
