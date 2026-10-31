# Solution — Gateway API Route

## The manifests

Apply both objects together:

```yaml
# gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: dojo-gw
  namespace: dojo-gw
spec:
  gatewayClassName: istio           # or 'nginx' / 'traefik' — any string; no controller
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
---
# httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web-route
  namespace: dojo-gw
spec:
  parentRefs:
    - name: dojo-gw
      namespace: dojo-gw
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: web-svc
          port: 80
```

```bash
kubectl apply -f gateway.yaml -f httproute.yaml
bash courses/course-07-networking-mesh/challenges/01-gateway-api-route/verify.sh
```

## Why each piece matters

**`gatewayClassName`** is the join key between your Gateway object and a running controller (e.g., Istio's `istio`, Kong's `kong`). Without it the API server rejects the object entirely. In this lab no controller is required, but the field must be present — which is why the verifier checks it.

**`parentRefs` on the HTTPRoute** is the Gateway API's answer to Ingress's `ingressClassName`. The route says "attach me to this Gateway." This separation means a platform team can own the Gateway (TLS certs, ports) and app teams can own their HTTPRoutes — no shared Ingress manifest to merge conflicts over.

**`backendRefs[].port`** must match the Service's port number, not the containerPort. This trips people up when they misread the Service manifest.

**Why not Ingress?** The legacy `networking.k8s.io/v1 Ingress` object has three problems Gateway API fixes:
1. Every annotation is controller-specific (nginx.ingress.kubernetes.io/..., haproxy.router.openshift.io/...) — not portable.
2. No first-class support for traffic splitting, header-based routing, or gRPC.
3. A single object mixes infrastructure (which controller/class) and routing (which Service) — Gateway API separates these into Gateway (infra team) and HTTPRoute (app team).

## Hardening preview

In production you want:
- `allowedRoutes.namespaces.from: Selector` instead of `Same` — explicit cross-namespace access control.
- A TLS listener with `certificateRefs` pointing to a cert Secret (or cert-manager Certificate).
- `ReferenceGrant` objects in app namespaces to grant the Gateway permission to reach cross-namespace Services.
