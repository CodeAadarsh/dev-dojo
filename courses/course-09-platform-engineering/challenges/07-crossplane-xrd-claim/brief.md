# Crossplane: Author an XRD, Composition & Claim

Your platform team has decided to give developers a self-service "object store" API. Instead of handing them AWS docs and IAM policies, they'll file a Kubernetes Claim — the same way they create any other resource. Your job: build the three-layer API that makes that possible.

## Prerequisites

Crossplane must be installed with `provider-nop` (a no-op provider that marks all Managed Resources `Ready: True` without calling any cloud API — perfect for dojo work):

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system \
  --create-namespace \
  --version 1.15.0 \
  --wait --timeout 5m

# Install the no-op provider for local testing
kubectl apply -f - <<'EOF'
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-nop
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-nop:v0.3.0
EOF
kubectl wait provider/provider-nop --for=condition=Healthy --timeout=120s
```

## Mission

Build the Crossplane object hierarchy in namespace `dojo-crossplane`:

**Layer 1 — Define the API (`CompositeResourceDefinition`):**

Create an XRD with these exact attributes:
- `metadata.name`: `xobjectstores.platform.dojo`
- `spec.group`: `platform.dojo`
- `spec.names.kind`: `XObjectStore`
- `spec.claimNames.kind`: `ObjectStore`, `spec.claimNames.plural`: `objectstores`
- One version `v1alpha1`, `served: true`, `referenceable: true`
- Schema: `spec.parameters.region` (string, required, enum: `["ap-south-1", "us-east-1"]`)

**Layer 2 — Implement the API (`Composition`):**

Create a Composition named `objectstore-nop.platform.dojo` that:
- References `compositeTypeRef.apiVersion: platform.dojo/v1alpha1`, `kind: XObjectStore`
- Has at least one resource entry using `provider-nop`'s `apiVersion: nop.crossplane.io/v1alpha1`, `kind: NopResource`
- Patches `spec.parameters.region` from the XR into `spec.forProvider.conditionAfter[0].conditionType`

**Layer 3 — File a Claim:**

Create a Claim in namespace `dojo-crossplane`:
- `apiVersion: platform.dojo/v1alpha1`, `kind: ObjectStore`
- `metadata.name`: `my-store`
- `spec.parameters.region`: `ap-south-1`

The verifier checks:
1. XRD `xobjectstores.platform.dojo` exists and is `Established`.
2. XRD `spec.claimNames.kind` is `ObjectStore`.
3. Composition `objectstore-nop.platform.dojo` exists and `compositeTypeRef.kind` is `XObjectStore`.
4. ObjectStore Claim `my-store` exists in namespace `dojo-crossplane`.

The verifier does **not** check live reconciliation (no `READY: True` requirement) — this is about authoring the right objects, not about provider runtime.

## Rules of engagement

- Namespace `dojo-crossplane` is created by setup.sh.
- The XRD, Composition, and Claim are all cluster-scoped except the Claim (which is namespace-scoped).
- Tip: wait for the XRD to be `Established` before creating the Claim — otherwise the API isn't registered yet.

## Why this matters

The Claim is what a developer sees. The XRD is the API contract your platform team publishes. The Composition is the implementation detail developers never touch. Understanding this separation — who owns which layer — is the defining concept of platform engineering: abstraction at the API layer.
