# Solution — Crossplane: Author an XRD, Composition & Claim

Three objects, applied in order: XRD → wait for Established → Composition → Claim.

## Step 1: The CompositeResourceDefinition

```yaml
# xrd-objectstore.yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xobjectstores.platform.dojo
spec:
  group: platform.dojo
  names:
    kind: XObjectStore
    plural: xobjectstores
  claimNames:
    kind: ObjectStore
    plural: objectstores
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
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
                  required: ["region"]
                  properties:
                    region:
                      type: string
                      enum: ["ap-south-1", "us-east-1"]
```

```bash
kubectl apply -f xrd-objectstore.yaml
kubectl wait --for=condition=Established \
  xrd/xobjectstores.platform.dojo --timeout=60s
```

After `Established`, two new API types are registered: `xobjectstores.platform.dojo` (cluster-scoped) and `objectstores.platform.dojo` (namespace-scoped Claims).

## Step 2: The Composition

```yaml
# composition-objectstore-nop.yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: objectstore-nop.platform.dojo
  labels:
    provider: nop
spec:
  compositeTypeRef:
    apiVersion: platform.dojo/v1alpha1
    kind: XObjectStore
  resources:
    - name: nop-bucket
      base:
        apiVersion: nop.crossplane.io/v1alpha1
        kind: NopResource
        spec:
          forProvider:
            conditionAfter:
              - conditionType: Ready
                conditionStatus: "True"
                time: 5s
          providerConfigRef:
            name: default
      patches:
        - type: FromCompositeFieldPath
          fromFieldPath: spec.parameters.region
          toFieldPath: spec.forProvider.conditionAfter[0].conditionType
```

```bash
kubectl apply -f composition-objectstore-nop.yaml
```

## Step 3: The Claim

```yaml
# objectstore-claim.yaml
apiVersion: platform.dojo/v1alpha1
kind: ObjectStore
metadata:
  name: my-store
  namespace: dojo-crossplane
spec:
  parameters:
    region: ap-south-1
```

```bash
kubectl apply -f objectstore-claim.yaml

# Check it was accepted
kubectl -n dojo-crossplane get objectstores

# Run the verifier
bash courses/course-09-platform-engineering/challenges/07-crossplane-xrd-claim/verify.sh
```

## Why each piece matters

**XRD**: The schema under `spec.parameters` is the developer-facing API contract. The `enum` on `region` is infrastructure policy encoded as a schema — no Rego, no Kyverno needed for this constraint. Adding a version (`v1beta1`) later and keeping `v1alpha1.served: true` gives you a graceful upgrade path.

**Composition**: The `compositeTypeRef` is the binding — it ties this implementation to the XRD. A typo here is silent (the Composition is accepted but never selected). The `resources[*].base` is a template that gets cloned and modified by `patches` for each XR. The `provider-nop` here simulates a cloud provider response without actually calling AWS.

**Claim**: This is what a developer applies. The XR (CompositeResource) is auto-created by Crossplane at cluster scope — the developer never manages it. The developer only sees `objectstores` in their namespace, not `xobjectstores` cluster-wide. That namespace-scoping is intentional: it allows RBAC to be applied at the team namespace level.

## What happens next (if this were a real provider)

```bash
# With a real provider (provider-aws), the XR would show:
kubectl get xobjectstore -o custom-columns='NAME:.metadata.name,SYNCED:.status.conditions[?(@.type=="Synced")].status,READY:.status.conditions[?(@.type=="Ready")].status'

# The underlying Managed Resources would appear:
kubectl get managed

# And errors surface in the XR's events, not the Claim's:
kubectl describe xobjectstore <name> | tail -20
```
