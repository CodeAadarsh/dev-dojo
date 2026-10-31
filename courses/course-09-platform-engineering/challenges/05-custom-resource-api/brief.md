# Custom Resource API — Environment

The platform team wants to stop managing `ConfigMaps` full of freeform JSON to describe deployment environments. The current system breaks whenever a developer typos `"Prod"` instead of `"prod"`. You're asked to design a first-class Kubernetes API object: an **Environment** resource that the API server validates.

This is the core move behind every operator framework (Argo, Crossplane, cert-manager, Flux): you extend the Kubernetes API with domain-specific objects, and suddenly `kubectl get environments` is a legitimate ops command.

## Prereqs

No add-ons required — CRDs are a core Kubernetes feature. The dojo cluster must be running (`kind-dojo` context).

## Mission

1. **Define a CRD** with:
   - `group: platform.dojo`
   - `kind: Environment` (plural: `environments`)
   - `scope: Namespaced`
   - OpenAPI schema with `spec.tier` as a **required** string, enumerated to exactly `["dev", "stage", "prod"]`

2. **Wait for the CRD to reach `Established` condition** (the API server must accept it before you can use it).

3. **Create an Environment CR** in namespace `dojo-crd2` with a valid `spec.tier` value.

The verifier checks **all** of the following:

- CRD `environments.platform.dojo` exists and its `.status.conditions[type=Established].status` is `True`.
- At least one Environment CR exists in namespace `dojo-crd2`.
- That CR's `spec.tier` is one of `dev`, `stage`, or `prod`.

```bash
bash courses/course-09-platform-engineering/challenges/05-custom-resource-api/verify.sh
```

## Why schema validation matters

Without an OpenAPI schema on the CRD, the API server accepts any shape. A developer can set `spec.tier: Prod` (capital P), `spec.tier: production`, or omit it entirely — and the breakage surfaces at runtime when the controller tries to reconcile. With `x-kubernetes-validations` or a simple `enum`, the API server rejects the bad value at admission: the error is immediate, close to the mistake, and in `kubectl apply` output rather than a cryptic controller log 10 minutes later.

## Extraction paths for the CRD check

```bash
kubectl get crd environments.platform.dojo
kubectl get crd environments.platform.dojo -o jsonpath='{.status.conditions[?(@.type=="Established")].status}'

kubectl -n dojo-crd2 get environments
kubectl -n dojo-crd2 get environments <name> -o yaml
```
