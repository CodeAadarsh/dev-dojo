# Solution — Expose Me

The `shop` pods are running and labelled `app=shop`; they just have nothing routing to them. Add a ClusterIP Service whose selector matches that label on port 80.

## The one-liner (imperative)

```bash
kubectl -n dojo-expose expose deployment shop \
  --name=shop --port=80 --target-port=80 --selector=app=shop
```

`kubectl expose` reads the Deployment's pod template labels and builds a Service for you. `--port` is the port the Service listens on; `--target-port` is the container port it forwards to (both 80 here).

## The declarative version (what you'd commit)

```yaml
# shop-svc.yaml
apiVersion: v1
kind: Service
metadata:
  name: shop
  namespace: dojo-expose
spec:
  type: ClusterIP          # default; stable virtual IP, in-cluster only
  selector:
    app: shop              # the continuous query that finds the pods
  ports:
    - name: http
      port: 80             # the Service's port
      targetPort: 80       # the container's port
      protocol: TCP
```

```bash
kubectl apply -f shop-svc.yaml
kubectl -n dojo-expose get svc,endpoints shop
bash courses/course-01-ops-security/challenges/04-expose-me/verify.sh
```

## Why each piece matters

- **`selector: app: shop`** is the whole game. The endpoints controller continuously watches for `Ready` pods with this label and publishes their IPs into an EndpointSlice. Get the label wrong (`app: Shop`, `app: shop-frontend`, or a selector in the wrong namespace) and you get a Service with a green `kubectl get svc` and **zero endpoints** — connections hang. Always confirm with `kubectl -n dojo-expose get endpoints shop` that the address list is non-empty.
- **`port` vs `targetPort`** — these differ in the real world (a Service on `80` fronting a container on `8080` is common). The Service port is the stable contract; `targetPort` can be a number or a **named** container port, which is the robust choice because it survives the container port changing.
- **`type: ClusterIP`** keeps this internal. `NodePort` and `LoadBalancer` build *on top of* ClusterIP — they all still depend on the selector resolving to ready endpoints. Fix the ClusterIP first; everything else is layered on it.

## Prove it actually routes

```bash
# resolve + hit the service from inside the cluster
kubectl -n dojo-expose run tmp --rm -it --image=nicolaka/netshoot --restart=Never -- \
  sh -c 'nslookup shop.dojo-expose.svc.cluster.local; curl -s -o /dev/null -w "%{http_code}\n" http://shop.dojo-expose/'
# -> 200
```

Watch the dataplane follow the pods: delete a pod and the EndpointSlice updates within a second as the replacement goes Ready — no Service change needed. That churn-tolerance is exactly why you route to a Service and never to a pod IP.

## Optional — front it with Ingress (host/path routing)

ClusterIP is in-cluster only. To expose `shop` by hostname you add an Ingress, which needs an ingress controller:

```bash
bash labs/bootstrap/install-ingress.sh   # installs ingress-nginx into the cluster
```

```yaml
# shop-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop
  namespace: dojo-expose
spec:
  ingressClassName: nginx
  rules:
    - host: shop.dojo.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: shop
                port:
                  number: 80
```

The Ingress still points at the **Service**, which still depends on the selector and endpoints you just fixed — the verifier deliberately stops at Service + Endpoints so it passes whether or not you install the controller.

## Hardening preview

A bare ClusterIP is reachable by **every** pod in the cluster — there is no default deny. In a later module you'll put a `NetworkPolicy` in front of `shop` so only the gateway namespace can open `:80`, turning this flat network into a segmented one. Exposure and least-privilege reachability are two different jobs; this challenge is only the first.
