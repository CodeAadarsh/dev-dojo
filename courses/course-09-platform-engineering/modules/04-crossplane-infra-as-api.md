# Crossplane & Infra-as-API

> **Module 04 · Course 09** — Terraform provisions infra. Kubernetes reconciles state. What if provisioning infra *was* reconciling state? Crossplane merges the two worlds: your cloud resources become custom Kubernetes objects, and the same `kubectl apply` that scales your app now creates an RDS instance. The cluster becomes the control plane *for* your control planes.

This module is not an argument that Crossplane replaces Terraform everywhere. It's an argument for knowing when owning a control plane pays off — and a deep dive into the machinery (XRDs, Compositions, Claims, Providers) that makes it work.

---

## The control-plane-of-control-planes mental model

A Crossplane installation is a set of Kubernetes controllers that watch your cluster for custom resources and turn them into API calls to AWS/GCP/Azure/anything-with-a-provider. The execution chain:

```
Developer applies a Claim
        │
        ▼
Crossplane controller reads the matching Composition
        │
        ▼
Composition engine creates or patches Managed Resources
        │
        ▼
Provider controller reconciles Managed Resources against real infra
        │
        ▼
Status propagates back up: Claim → XR → Managed Resources
```

The critical insight: **infra state becomes Kubernetes state.** A Crossplane-managed S3 bucket has a `Bucket` object in your cluster. Delete the object — Crossplane deletes the real bucket. Drift the bucket ACL out-of-band — the provider reconciles it back. The cluster IS the source of truth, not a `.tfstate` file on a developer's laptop or in an S3 backend.

### Crossplane vs Terraform

| | Terraform | Crossplane |
|---|---|---|
| State location | `.tfstate` file / remote backend | etcd (as Kubernetes custom resources) |
| Reconciliation | On `terraform apply` (pull, manual) | Continuous controller loop (push, automatic) |
| Drift detection | `terraform plan` (you must run it) | Controller detects and repairs without intervention |
| Multi-team self-service | Wrapper modules + PR + CI pipeline | Compositions + Claims (just `kubectl apply`) |
| Developer interface | HCL files, understand Terraform | `kubectl apply -f my-db-claim.yaml` |
| Where it runs | Your laptop or CI runner | In-cluster operator — always running |
| Access control | IAM roles on CI, Terraform Cloud | Kubernetes RBAC + provider credentials |

Crossplane doesn't win everywhere. Terraform has a richer ecosystem, better import UX for existing infra, and is embedded in most organizations' muscle memory. Where Crossplane shines: when you want developers to self-service infra provisioning *without* touching Terraform or understanding cloud APIs — they apply a Claim like any other Kubernetes object.

---

## The four-layer object hierarchy

```
XRD (CompositeResourceDefinition)
  └── defines the API schema — group, kind, versions, openAPIV3Schema
      The "what can developers ask for" layer.

Composition
  └── maps XRD schema to Managed Resources via patches + transforms
      The "how we implement it" layer. Multiple Compositions can satisfy one XRD
      (different cloud providers, regions, cost tiers).

XR (CompositeResource)
  └── auto-created by Crossplane when a Claim is filed
      Cluster-scoped. Holds the actual composed state + status.

Claim
  └── what a developer applies — namespace-scoped, schema matches the XRD
      Developers never see XRs or Managed Resources.
```

Separately, the provider layer:

```
Provider           — installs the controller for a cloud (e.g., provider-aws)
ProviderConfig     — auth config: credentials, region, endpoint
Managed Resources  — the atomic cloud objects (Bucket, RDSInstance, VPC, etc.)
```

A platform team authors the XRD + Composition once. Developers file Claims. The isolation is the point: a developer can provision a database without knowing the provider API, the account ID, or the VPC subnet CIDR.

---

## XRDs: your infra API schema

An `XRD` is similar to a `CustomResourceDefinition` but Crossplane-specific: it auto-generates both the XR kind and the Claim kind from a single object, and it ties to the Composition selection machinery.

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xobjectstores.platform.example.com
spec:
  group: platform.example.com
  names:
    kind: XObjectStore         # the CompositeResource kind (cluster-scoped)
    plural: xobjectstores
  claimNames:
    kind: ObjectStore          # the Claim kind (namespace-scoped)
    plural: objectstores
  versions:
    - name: v1alpha1
      served: true
      referenceable: true      # exactly one version must be referenceable
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: ["parameters"]
              properties:
                parameters:
                  type: object
                  required: ["region", "versioning"]
                  properties:
                    region:
                      type: string
                      enum: ["us-east-1", "eu-west-1"]
                    versioning:
                      type: boolean
```

Two things worth internalizing:

1. **`referenceable: true`** marks the version a Composition binds to. If you version the XRD (`v1alpha1 → v1beta1`), only one can be referenceable at a time.
2. The `spec.parameters` sub-schema is the *developer-facing contract*. It hides the full AWS surface area behind a narrow, validated set of inputs. An `enum` on `region` is infrastructure policy expressed as a schema.

Wait for Established status before creating Claims:

```bash
kubectl wait --for=condition=Established xrd/xobjectstores.platform.example.com --timeout=60s
kubectl get xrd xobjectstores.platform.example.com -o jsonpath='{.status.conditions[?(@.type=="Established")].status}'
# -> True
```

---

## Compositions: the implementation

A `Composition` maps the XRD schema to one or more Managed Resources using `patch-and-transform` pipelines. Each `resources[*]` entry has a `base` (the Managed Resource template) and `patches` (field mappings from the XR/Claim into the template).

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: objectstore-s3.platform.example.com
  labels:
    provider: aws
spec:
  compositeTypeRef:
    apiVersion: platform.example.com/v1alpha1
    kind: XObjectStore            # must match XRD names.kind exactly
  resources:
    - name: s3-bucket
      base:
        apiVersion: s3.aws.upbound.io/v1beta1
        kind: Bucket
        spec:
          forProvider:
            region: us-east-1     # overridden by patch below
          providerConfigRef:
            name: aws-default
      patches:
        - type: FromCompositeFieldPath
          fromFieldPath: spec.parameters.region
          toFieldPath: spec.forProvider.region
        - type: FromCompositeFieldPath
          fromFieldPath: metadata.name
          toFieldPath: metadata.annotations["crossplane.io/external-name"]
    - name: s3-versioning
      base:
        apiVersion: s3.aws.upbound.io/v1beta1
        kind: BucketVersioning
        spec:
          forProvider:
            bucketSelector:
              matchControllerRef: true   # link to the Bucket in this same Composition
            versioningConfiguration:
              - status: Suspended
      patches:
        - type: FromCompositeFieldPath
          fromFieldPath: spec.parameters.versioning
          toFieldPath: spec.forProvider.versioningConfiguration[0].status
          transforms:
            - type: map
              map:
                "true": Enabled
                "false": Suspended
```

The `patches` array is where composition complexity lives. `FromCompositeFieldPath` copies a value from the XR (and by extension the Claim) into the Managed Resource field. The `transforms` block handles type coercions — here a boolean becomes an enum string. Other transform types: `string` (format + convert), `math` (multiply), `convert`, `regexp`.

A Composition can also select which Composition to use via `compositionSelector` on the Claim:

```bash
# claim can specify: spec.compositionSelector.matchLabels.provider: aws
# This selects the Composition with that label
```

---

## Claims: the developer interface

The developer never writes XRDs or Compositions. They write:

```yaml
apiVersion: platform.example.com/v1alpha1
kind: ObjectStore
metadata:
  name: my-uploads
  namespace: team-alpha
spec:
  parameters:
    region: eu-west-1
    versioning: true
```

`kubectl apply -f my-uploads.yaml`. That's it. Crossplane creates an XR (cluster-scoped, named `team-alpha-my-uploads` by convention), the Composition creates a `Bucket` + `BucketVersioning` Managed Resource, the provider calls the AWS API, and status propagates back up:

```bash
kubectl get objectstore my-uploads -n team-alpha -o wide
# NAME         SYNCED   READY   CONNECTION-SECRET   AGE
# my-uploads   True     True                        2m

kubectl get objectstore my-uploads -n team-alpha \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# -> True

kubectl describe objectstore my-uploads -n team-alpha
# Events:
#   Type     Reason                   Message
#   ----     ------                   -------
#   Normal   ComposeResources         Successfully composed resources
#   Normal   PublishConnectionDetails  Successfully published connection details
```

---

## ProviderConfig: connecting to the cloud

```yaml
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: aws-default
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: aws-credentials
      key: creds
```

The referenced Secret must contain AWS credentials in ini format:

```bash
kubectl -n crossplane-system create secret generic aws-credentials \
  --from-literal=creds="$(cat ~/.aws/credentials)"
```

For local dojo work, use `provider-nop` — a no-op provider that accepts all Managed Resources and marks them `Ready: True` without calling any cloud API. Perfect for testing Composition logic:

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace \
  --version 1.15.0

# install the no-op provider for local testing
kubectl apply -f - <<'EOF'
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-nop
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-nop:v0.3.0
EOF
```

---

## Debugging Crossplane

This is where every production Crossplane operator has scars. Compositions fail silently at the wrong level if you don't know the object hierarchy.

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Claim stuck, `READY: False`, no error message | XRD not yet `Established`, or `compositeTypeRef` mismatch in Composition | Check XRD status first: `kubectl get xrd <name> -o jsonpath='{.status.conditions}'` |
| XRD is `Established` but no XR is auto-created when Claim is applied | Claim's API group/version doesn't match XRD `spec.group` + `spec.versions[*].name` | `kubectl get objectstores.platform.example.com` — if 'no resources' the API isn't registered; re-check XRD group |
| XR created but Managed Resource never appears | `compositeTypeRef.apiVersion` in Composition has a typo (wrong group or version string) | Compare `compositeTypeRef.apiVersion` exactly against the XRD `spec.group`/`spec.versions[*].name` — one character off is silent |
| Managed Resource `SYNCED: False`, message `cannot resolve references` | A `FromCompositeFieldPath` patch references a field that doesn't exist on the XR | `kubectl describe` the *XR* (not the Claim) — it has the full composition trace; fix the `fromFieldPath` path |
| Provider pod `CrashLoopBackOff` | Wrong credentials format, missing ProviderConfig, or provider package not Healthy | `kubectl -n crossplane-system logs <provider-pod>` — credential errors are explicit here |
| `SYNCED: True` but `READY: False` after several minutes | The cloud resource is provisioning (normal) or there's a cloud-side error | `kubectl describe managed <name>` — `status.atProvider` and events surface cloud errors |
| Multiple Compositions match one XRD, wrong one is selected | Missing or mismatched `compositionSelector` on the Claim | Add `spec.compositionSelector.matchLabels` to the Claim or set `spec.defaultCompositionRef` on the XRD |
| XRD schema updated but existing Managed Resources misbehave | New required field added to XRD but not patched in Composition | A field missing from the patch path is silently not set — add the patch to the Composition; test with `--dry-run=server` on the Claim |

### Diagnose each — the exact commands

**Composition not ready:**

```bash
# Step 1: Is the XRD Established?
kubectl get xrd -o custom-columns='NAME:.metadata.name,ESTABLISHED:.status.conditions[?(@.type=="Established")].status'

# Step 2: Check the XR (richer than the Claim)
kubectl get composite -o wide    # lists all XRs across all types
XR_NAME=$(kubectl get composite -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
kubectl describe composite "$XR_NAME"

# Step 3: Provider logs — surface credential and reconcile errors
kubectl -n crossplane-system logs -l pkg.crossplane.io/revision --tail=50 --prefix
```

**Provider credential failure:**

```bash
# Is the ProviderConfig pointing at an existing Secret?
kubectl get providerconfig -o yaml | grep -A5 secretRef

# Does the Secret exist with the right key?
kubectl -n crossplane-system get secret aws-credentials -o jsonpath='{.data}' \
  | tr -d '{}' | tr ',' '\n'

# Is the Provider package Healthy?
kubectl get providers -o custom-columns='NAME:.metadata.name,HEALTHY:.status.conditions[?(@.type=="Healthy")].status,INSTALLED:.status.conditions[?(@.type=="Installed")].status'
```

**XRD schema mismatch — dry-run a Claim:**

```bash
# Validate Claim against the server schema without creating it
kubectl apply -f my-claim.yaml --dry-run=server

# Inspect what schema the XRD exposes
kubectl get xrd xobjectstores.platform.example.com \
  -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.parameters}'
```

> **War story.** A team added a `spec.parameters.encryption` field to a production XRD after it had been deployed for six months. They updated the XRD schema and the Composition, but one of three Compositions (the "legacy-gcp" one serving a single tenant) was missed. Every new Claim that landed on the GCP Composition was created and reconciled without the `encryption` field — the provider accepted it, the Managed Resource was created, but it was unencrypted. The bug was invisible in `kubectl get` because the Managed Resource showed `READY: True`. It surfaced in a quarterly audit three months later. The fix: `kyverno` generate policy that watches for Compositions and runs a structural diff against the XRD schema. Treat XRD version bumps the same way you treat breaking API changes — with a validation gate.

---

## Checkpoint

You're ready for the challenge when you can, without looking anything up:

1. Explain what auto-creates the XR when a developer applies a Claim.
2. Name the four layers in the Crossplane object hierarchy from developer-facing to cloud-facing.
3. Write the `compositeTypeRef` block in a Composition targeting `XObjectStore` in group `platform.example.com/v1alpha1`.
4. Say which object you inspect first when a Claim is stuck: the Claim, the XR, or the provider pod logs — and why.
5. Explain why `referenceable: true` must be set on exactly one XRD version.
6. Describe what `provider-nop` does and why it's useful for local dojo work.
7. Trace what happens when someone manually deletes the S3 bucket that a Managed Resource controls.
8. Identify why a `FromCompositeFieldPath` patch is silently skipped when `fromFieldPath` doesn't exist in the Claim.

➡ Next up: the **Custom Resource API** challenge — you'll extend Kubernetes with a schema-validated `Environment` CRD, the same move that underpins Crossplane XRDs.
