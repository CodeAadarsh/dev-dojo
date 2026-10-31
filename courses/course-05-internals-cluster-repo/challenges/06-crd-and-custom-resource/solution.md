# Solution — Teach the API a New Word

Extending Kubernetes is two steps: **define the kind** (a CRD), then **create instances** of it (custom resources). The CRD is how every operator (ArgoCD `Application`, cert-manager `Certificate`, Prometheus `ServiceMonitor`) plugs into the API.

## 1. Define the CRD

```yaml
# widget-crd.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.dojo.local          # MUST be <plural>.<group>
spec:
  group: dojo.local
  scope: Namespaced
  names:
    plural: widgets
    singular: widget
    kind: Widget
    shortNames: [wi]
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: [size]            # <-- the verifier checks this
              properties:
                size:
                  type: string
                  enum: [small, medium, large]
                replicas:
                  type: integer
                  minimum: 1
      additionalPrinterColumns:
        - name: Size
          type: string
          jsonPath: .spec.size
```

Apply it and wait for the API server to register the type:

```bash
kubectl apply -f widget-crd.yaml
kubectl wait --for=condition=Established crd/widgets.dojo.local --timeout=30s
```

`Established=True` means the api-server now serves `/apis/dojo.local/v1/...` and `kubectl get widgets` works.

## 2. Create a Widget

```yaml
# my-widget.yaml
apiVersion: dojo.local/v1
kind: Widget
metadata:
  name: blue-widget
  namespace: dojo-crd
spec:
  size: medium
  replicas: 3
```

```bash
kubectl apply -f my-widget.yaml
kubectl -n dojo-crd get widgets          # your new first-class API object
bash courses/course-05-internals-cluster-repo/challenges/06-crd-and-custom-resource/verify.sh
```

## Why this matters

- The **schema** (`openAPIV3Schema`) is enforced by the api-server's admission path: try creating a Widget without `spec.size` and it's rejected *before* anything stores it. That's structural validation for free — the same mechanism that makes a typo'd `Deployment` field get rejected.
- A CRD alone is just **data** the api-server stores in etcd. It does nothing until a **controller/operator** watches `Widget` objects and reconciles them toward desired state (e.g. creating Deployments for each Widget). That watch→reconcile loop is the operator pattern — the subject of module 05.
- `additionalPrinterColumns` is why `kubectl get <crd>` can show custom columns like a built-in resource — a small but real UX win operators ship.

## Cleanup

```bash
kubectl delete -f my-widget.yaml
kubectl delete crd widgets.dojo.local     # deleting the CRD deletes ALL Widgets — be careful in prod
```
