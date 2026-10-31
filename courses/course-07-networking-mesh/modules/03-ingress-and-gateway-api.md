# Ingress & the Gateway API

> **Module 03 · Course 07** — Ingress has been Kubernetes' L7 entry point since 1.2 and remains how most clusters expose HTTP services today. The Gateway API is its successor: role-separated, multi-tenant by design, and now stable (v1 since Kubernetes 1.28). You need both — most clusters you inherit run Ingress; most you design from scratch should use Gateway API. The debugging overlap is 80% identical, and the remaining 20% is where teams get burned crossing them up.

---

## Ingress

An Ingress resource describes L7 routing rules in YAML. It does **nothing** on its own — an **Ingress controller** watches Ingress objects and programs a reverse proxy (nginx, HAProxy, Envoy, Contour, Traefik…) to implement them. The split between spec (what you want) and controller (how it's implemented) is fundamental and the source of most `ImplementationSpecific` footguns.

```
Internet
  └─ external IP (NodePort or cloud LB)
       └─ Ingress Controller Pod (nginx, envoy, traefik, ...)
            │ reads Ingress objects
            └─ routes to backend Services → pods
```

### Installing the nginx Ingress controller on kind

```bash
bash labs/bootstrap/install-ingress.sh

# verify the controller pod is Running and the Service has an external IP (or NodePort)
kubectl -n ingress-nginx get pods -l app.kubernetes.io/name=ingress-nginx
kubectl -n ingress-nginx get svc ingress-nginx-controller

# get the NodePort for HTTP (kind doesn't provision real LB IPs)
HTTP_PORT=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
NODE_IP=$(kubectl get node dojo-control-plane \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
echo "Test with: curl -H 'Host: app.dojo.local' http://${NODE_IP}:${HTTP_PORT}/"
```

### A minimal Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
  namespace: dojo-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: app.dojo.local
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api-svc
                port:
                  number: 80
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend-svc
                port:
                  number: 80
```

**`ingressClassName`** links the resource to a specific IngressClass object:

```bash
kubectl get ingressclass
# NAME    CONTROLLER                     PARAMETERS   AGE
# nginx   k8s.io/ingress-nginx           <none>       2d
```

Without `ingressClassName`, any controller with `--watch-ingress-without-class=true` can pick it up. In a cluster with two controllers (e.g., nginx + HAProxy), both may try to program the same Ingress, causing a split-brain where config changes take effect on one controller but not the other.

### pathType

| pathType | Match rule | Example: path `/api` matches |
|---|---|---|
| `Exact` | URL must equal the path exactly | `/api` only — not `/api/` or `/api/v1` |
| `Prefix` | Split on `/`, check each segment prefix | `/api`, `/api/`, `/api/v1`, `/api/v2` |
| `ImplementationSpecific` | Controller decides — often regex | Varies; nginx allows regex here |

`Prefix` is correct 95% of the time. The catch: nginx's `Prefix` match strips the matched prefix from the upstream request *unless* you add `nginx.ingress.kubernetes.io/rewrite-target`. Without the rewrite, `/api/v1/users` reaches your backend as `/api/v1/users` — with it, it reaches as `/v1/users` (or `/` if you rewrite to `/`). Getting this wrong causes 404s from the backend even though the Ingress controller returns 200 routing to it.

### TLS termination

```yaml
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - app.dojo.local
      secretName: app-tls           # must contain tls.crt and tls.key
  rules:
    - host: app.dojo.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend-svc
                port:
                  number: 80
```

The controller terminates TLS at the proxy and forwards plain HTTP to the backend unless you annotate `nginx.ingress.kubernetes.io/backend-protocol: HTTPS`. In production use cert-manager to manage the TLS Secret — never rotate certs by hand.

```bash
# create a self-signed cert for dojo testing
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/tls.key -out /tmp/tls.crt \
  -subj '/CN=app.dojo.local' -addext 'subjectAltName=DNS:app.dojo.local' 2>/dev/null

kubectl -n dojo-ingress create secret tls app-tls \
  --cert=/tmp/tls.crt --key=/tmp/tls.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## The Gateway API

The Gateway API (`gateway.networking.k8s.io`) fixes four structural limitations of Ingress:

1. **Role separation.** Infrastructure teams own `GatewayClass` + `Gateway`. App teams own `HTTPRoute`. No shared YAML file, no annotation conflicts.
2. **Explicit multi-tenancy.** Cross-namespace references require a `ReferenceGrant`. An app team cannot silently reroute another team's traffic.
3. **Routing expressiveness.** Header matching, traffic weight splitting, redirects, rewrites — in the spec, not in controller-specific annotations.
4. **Protocol extensibility.** `GRPCRoute`, `TCPRoute`, `TLSRoute` are first-class types. Ingress is HTTP-only.

### Resource hierarchy

```
GatewayClass   (cluster-scoped, owned by infra/platform team)
  └─ Gateway   (namespaced, the entry point; programs the actual LB)
       └─ HTTPRoute   (namespaced, routing rules; attaches to the Gateway)
            └─ Service (backend)
```

**GatewayClass** — created once by the controller install, maps to a specific controller binary:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: nginx
spec:
  controllerName: k8s.io/ingress-nginx
```

**Gateway** — the shared entry point; defines listeners (protocol + port + TLS config):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared-gw
  namespace: dojo-gateway
spec:
  gatewayClassName: nginx
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All        # or Selector with a label filter
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: app-tls
            namespace: dojo-gateway
      allowedRoutes:
        namespaces:
          from: All
```

**HTTPRoute** — the routing rules, owned by the app team in their own namespace:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api-route
  namespace: dojo-app
spec:
  parentRefs:
    - name: shared-gw
      namespace: dojo-gateway
      sectionName: http         # attach to the 'http' listener specifically
  hostnames:
    - "api.dojo.local"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1
        - headers:
            - name: X-Canary
              value: "true"
      backendRefs:
        - name: api-svc-canary
          namespace: dojo-app
          port: 80
    - matches:
        - path:
            type: PathPrefix
            value: /v1
      backendRefs:
        - name: api-svc
          namespace: dojo-app
          port: 80
          weight: 90
        - name: api-svc-canary
          namespace: dojo-app
          port: 80
          weight: 10
```

Traffic splitting (`weight: 90` / `weight: 10`) is in the spec — controller-agnostic. Compare that to the nginx annotation approach (`nginx.ingress.kubernetes.io/canary: "true"`, `nginx.ingress.kubernetes.io/canary-weight: "10"`, plus a duplicate Ingress resource). The Gateway API does it in one object with no controller-specific strings.

### ReferenceGrant: the explicit multi-tenancy boundary

An `HTTPRoute` in `dojo-app` that references a `Service` in `dojo-gateway` (or attaches to a `Gateway` in another namespace) requires a `ReferenceGrant` in the *target* namespace:

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-dojo-app-routes
  namespace: dojo-gateway        # the namespace being referenced
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: dojo-app        # the namespace making the reference
  to:
    - group: ""
      kind: Service
```

Without this grant, the HTTPRoute will have `ResolvedRefs: False` in its status. This is the core multi-tenancy improvement: a misconfigured annotation cannot reroute another team's traffic because cross-namespace access is opt-in at the target.

### Installing Gateway API CRDs on kind

The Gateway API CRDs must be installed separately from the controller (unless bundled):

```bash
# standard channel (HTTPRoute, GatewayClass, Gateway, ReferenceGrant)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml

# verify
kubectl get crd | grep gateway.networking.k8s.io

# if using nginx-ingress >= 1.9 with Gateway API support:
kubectl get gatewayclass
```

---

## When to use which

| Use Ingress when | Use Gateway API when |
|---|---|
| Cluster already has a working Ingress controller and no pressing reason to change | Starting fresh — the controller supports Gateway API (nginx-ingress ≥1.9, Envoy Gateway, Istio, Traefik v3, Cilium) |
| Single team owns all routing config | Multiple teams share one entry point |
| Simple host/path routing, no canary, no header matching | You need traffic splitting, header-based routing, redirects, or rewrites in the spec |
| You're writing ≤2 controller annotations to express a rule | You're writing >2 annotations — you've outgrown Ingress |
| Migrating to Gateway API is not worth the churn right now | Greenfield cluster or active platform re-architecture |

The practical inflection: if you find yourself duplicating an Ingress object just to express a canary split (which is what nginx-ingress canary mode requires), the annotation model has become the bottleneck.

---

## Debugging Ingress & Gateway API

80% of issues are one of: no/wrong controller, wrong className, backend has no ready endpoints, or a missing ReferenceGrant (Gateway API only).

| Symptom | Likely cause | Fix |
|---|---|---|
| Ingress `ADDRESS` column empty | No controller watching that `ingressClassName` | `kubectl get ingressclass`; check controller pod status |
| `curl` returns 404 from controller | Path not matched (wrong `pathType`, trailing slash, rewrite mismatch) | Check controller logs; test `Exact` vs `Prefix`; inspect nginx.conf inside controller |
| `curl` returns 502 / 503 | Backend service has no ready endpoints | `kubectl get endpointslices`; fix readinessProbe; check pod logs |
| `curl` returns 404 but controller logs show 200 | Rewrite strips the path prefix the backend expects | Match `rewrite-target` annotation to your app's expected base path |
| HTTPRoute `Accepted: False` | Gateway listener rejected the route (allowedRoutes restriction, wrong hostnames, wrong namespace) | `kubectl describe httproute`; check `status.parents[0].conditions` |
| HTTPRoute `ResolvedRefs: False` | Backend Service missing, wrong port, or missing ReferenceGrant for cross-ns | `kubectl get svc -n <ns>`; check ReferenceGrant in the target namespace |
| TLS returns wrong cert / plain HTTP on HTTPS port | Secret missing `tls.crt`/`tls.key`, wrong `secretName`, or controller can't read the secret | `kubectl get secret <name> -o jsonpath='{.data}'`; check controller RBAC |
| Works with `-H 'Host: app.dojo.local'` but not with bare IP | Expected — host-based routing requires the Host header | Use `--resolve` or `/etc/hosts` for local testing; add an IP-based rule if needed |

### The exact commands

**Ingress no ADDRESS:**

```bash
kubectl -n dojo-ingress get ingress
# NAME          CLASS   HOSTS            ADDRESS   PORTS   AGE
# web-ingress   nginx   app.dojo.local             80      5m
# ADDRESS blank = controller not watching this className

kubectl get ingressclass nginx
kubectl -n ingress-nginx get pods
kubectl -n ingress-nginx logs -l app.kubernetes.io/name=ingress-nginx --tail=30
# look for "the class nginx does not exist" or watch for reconcile errors
```

**502 from Ingress:**

```bash
# 502 = controller reached upstream but upstream failed (or no healthy pod)
kubectl -n dojo-ingress get endpointslices -l kubernetes.io/service-name=api-svc
# if empty or all ready=false → backend is the problem

# controller logs tell you which upstream and why it 502'd
kubectl -n ingress-nginx logs -l app.kubernetes.io/name=ingress-nginx --tail=50 | grep 502

# peek inside nginx.conf to verify the upstream block was actually written
kubectl -n ingress-nginx exec -it deploy/ingress-nginx-controller -- \
  nginx -T 2>/dev/null | grep -A10 'upstream.*dojo-ingress'
```

**HTTPRoute status inspection:**

```bash
# read the status conditions — this is the primary debug surface for Gateway API
kubectl -n dojo-app describe httproute api-route
# look for:
# status.parents[0].conditions:
#   - type: Accepted        → is the Gateway accepting this HTTPRoute?
#   - type: ResolvedRefs    → can it find the backend Service?

# Accepted: False usually means a namespace/hostname mismatch with the Gateway listener
kubectl -n dojo-gateway describe gateway shared-gw
# check .spec.listeners[].allowedRoutes

# ResolvedRefs: False: check the Service and the ReferenceGrant
kubectl -n dojo-app get svc api-svc
kubectl -n dojo-gateway get referencegrant
```

**TLS debugging:**

```bash
# confirm the secret has both required keys
kubectl -n dojo-gateway get secret app-tls \
  -o jsonpath='{range .data}{@}{"\n"}{end}'
# should list tls.crt and tls.key; missing key = controller won't load the cert

# test the actual TLS handshake end-to-end
INGRESS_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || \
  kubectl get node dojo-control-plane \
    -o jsonpath='{.status.addresses[0].address}')
HTTPS_PORT=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || echo 443)

kubectl run tls-check --rm -it --image=nicolaka/netshoot:v0.13 -- \
  curl -kv --resolve "app.dojo.local:${HTTPS_PORT}:${INGRESS_IP}" \
  "https://app.dojo.local:${HTTPS_PORT}/"
# look for: SSL connection using TLS 1.3
# and: subject: CN=app.dojo.local (not the controller's default self-signed cert)
```

**Wrong pathType causing 404:**

```bash
INGRESS_IP=$(kubectl get node dojo-control-plane \
  -o jsonpath='{.status.addresses[0].address}')
HTTP_PORT=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')

# test both slash variants
curl -v -H 'Host: app.dojo.local' "http://${INGRESS_IP}:${HTTP_PORT}/api"
curl -v -H 'Host: app.dojo.local' "http://${INGRESS_IP}:${HTTP_PORT}/api/"

# check what nginx actually generated for your host
kubectl -n ingress-nginx exec -it deploy/ingress-nginx-controller -- \
  nginx -T 2>/dev/null | grep -B2 -A15 'app.dojo.local'
# look at the 'location' blocks — Prefix `/api` generates location `/api`
```

> **War story.** A team had a Gateway API HTTPRoute that worked on staging but 404'd on production with the same controller version and the same manifests. After 45 minutes of diffing configs, the difference was one field: staging had `parentRefs[0].sectionName: http`; production omitted it. The Gateway had two listeners — `http` (port 80) and `https` (port 443). Without `sectionName`, the HTTPRoute silently attached to *both* listeners. On staging the HTTP listener happened to be first in the list and matched the plain-HTTP test. On production the HTTPS listener was first; the plain-HTTP test request didn't carry SNI, the HTTPS listener found no matching cert-to-hostname binding, and it returned 404. Adding `sectionName: http` fixed it in 10 seconds. The lesson: when a Gateway has more than one listener, always specify `sectionName` in `parentRefs`. Implicit "attach to all listeners" means your HTTPRoute's behavior depends on listener ordering in the Gateway spec, which you don't control and which can drift between environments.

---

## Checkpoint

You're ready for the Ingress and Gateway API challenges when you can, without looking anything up:

1. Explain `pathType: Prefix` vs `pathType: Exact` — give a URL that one matches and the other doesn't, then explain why `rewrite-target` matters with `Prefix`.
2. Describe the three-tier Gateway API hierarchy and which team or role owns each resource.
3. Write a `ReferenceGrant` that allows `HTTPRoute`s in namespace `dojo-app` to attach to a `Gateway` in namespace `dojo-gateway`.
4. Diagnose a 502 from nginx Ingress: the two resources to check first and the exact commands.
5. Read the conditions in a `kubectl describe httproute` output and explain what `Accepted: False` vs `ResolvedRefs: False` each tells you to fix.
6. Configure a 90/10 canary split in a single HTTPRoute and explain why this is a single-object operation in Gateway API but requires a duplicate Ingress object with nginx annotations.
7. Explain why `sectionName` in `parentRefs` prevents prod/staging divergence when a Gateway has multiple listeners.

➡ Next: **NetworkPolicy in depth** — from the default "pods talk to pods unrestricted" posture to default-deny with surgical allow rules, Calico GlobalNetworkPolicy for cluster-wide baselines, and how to forensically trace a silently dropped packet back to the policy that dropped it.
