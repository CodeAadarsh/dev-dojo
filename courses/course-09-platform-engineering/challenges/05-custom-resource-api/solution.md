# Solution — Custom Resource API — Environment

Two manifests: the CRD, then the CR.

```yaml
# environment-crd.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: environments.platform.dojo
spec:
  group: platform.dojo
  names:
    kind: Environment
    listKind: EnvironmentList
    plural: environments
    singular: environment
    shortNames:
      - env
  scope: Namespaced
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          required:
            - spec
          properties:
            spec:
              type: object
              required:
                - tier
              properties:
                tier:
                  type: string
                  enum:
                    - dev
                    - stage
                    - prod
                  description: Deployment tier for this environment.
                description:
                  type: string
      additionalPrinterColumns:
        - name: Tier
          type: string
          jsonPath: .spec.tier
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
```

```yaml
# env-staging.yaml
apiVersion: platform.dojo/v1alpha1
kind: Environment
metadata:
  name: staging
  namespace: dojo-crd2
spec:
  tier: stage
  description: "Staging environment for team Falcon"
```

Apply and verify:

```bash
kubectl apply -f environment-crd.yaml

# Wait for the CRD to become Established (~1–3s)
kubectl wait --for=condition=Established crd/environments.platform.dojo --timeout=30s

kubectl apply -f env-staging.yaml
bash courses/course-09-platform-engineering/challenges/05-custom-resource-api/verify.sh
```

## Why each piece matters

**`group: platform.dojo` and the fully qualified name.** The CRD's name in etcd is `<plural>.<group>` — that's the string you `kubectl get`. Group namespacing prevents collisions: `environments.platform.dojo` and `environments.fleet.io` coexist peacefully. Pick a domain you control.

**`scope: Namespaced` vs `Cluster`.** Namespaced CRDs behave exactly like Deployments — they live in a namespace, are governed by RBAC namespace scope, and appear in `kubectl -n dojo-crd2 get environments`. ClusterScoped CRDs (like Nodes, PersistentVolumes) are shared across all namespaces. For platform objects that represent tenant-level concepts (environments, feature flags, tenants), Namespaced is almost always right.

**OpenAPI `enum` on `spec.tier`.** The enum is enforced at admission by the API server's schema validator. Try applying a CR with `tier: Prod` (capital P) — you'll get a clear validation error:
```
The Environment "bad" is invalid: spec.tier: Unsupported value: "Prod": supported values: "dev", "stage", "prod"
```
This is the core value proposition of schema-validated CRDs over plain ConfigMaps.

**`additionalPrinterColumns`.** These define what `kubectl get environments` shows without `-o yaml`. The `Tier` column reads `.spec.tier` via jsonpath — same syntax as verifier scripts. Always add at least one domain-meaningful column; it makes the CR feel like a first-class API object.

**`kubectl wait --for=condition=Established`.** The API server processes a new CRD asynchronously — if you apply the CRD and immediately apply the CR, you'll hit `no matches for kind "Environment"` because the discovery cache hasn't updated yet. `kubectl wait` blocks until the condition is true. In CI pipelines, always add this step between CRD apply and CR apply.

## Prove the schema validation works

```bash
# This should fail with a validation error
kubectl -n dojo-crd2 apply -f - <<EOF
apiVersion: platform.dojo/v1alpha1
kind: Environment
metadata:
  name: bad-tier
spec:
  tier: production
EOF
# -> The Environment "bad-tier" is invalid: spec.tier: Unsupported value: "production"
```

## Attacker's view / hardening preview

A CRD with no schema (`x-kubernetes-preserve-unknown-fields: true`) is effectively a schema-less store — an attacker can embed arbitrary data (including Base64-encoded payloads) in custom fields that no admission webhook inspects. Always ship a schema. Pair with a validating admission webhook or Kyverno policy for rules too complex for OpenAPI (e.g., cross-field validation: `stage` environments must have `spec.replicas <= 3`).
