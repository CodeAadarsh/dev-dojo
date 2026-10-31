# Gateway API: Route Traffic the Right Way

A platform team has standardized on the **Gateway API** and removed the legacy Ingress controller. Your next service needs an HTTPRoute to receive external traffic — no more `networking.k8s.io/v1 Ingress` objects allowed.

Gateway API is the upstream successor to Ingress. It separates *infrastructure concerns* (which port/TLS the load balancer owns) from *routing concerns* (which Service to forward to), letting platform teams and app teams manage their own objects independently. It is now stable in Kubernetes 1.31+ and the first thing a senior engineer reaches for when Ingress starts feeling limiting.

## Prerequisites

Gateway API CRDs must be installed before running `setup.sh`. Install the standard channel (stable) CRDs once per cluster:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

Verify the CRDs landed:

```bash
kubectl get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io
```

If the cluster has no Gateway controller (kind ships none), the Gateway will never flip to `Programmed=True` — that is fine for this challenge. The verifier only checks that the **objects are authored correctly**, not that a controller is reconciling them. This mirrors real-world day-1 work: you write the objects, the platform team installs the controller.

## Mission

The setup script deploys a Service `web-svc` in namespace `dojo-gw` backed by a single-replica nginx pod.

Your task — create the following two objects in `dojo-gw`:

1. A **`Gateway`** (`gateway.networking.k8s.io/v1`, or `v1beta1`) named `dojo-gw`:
   - `gatewayClassName: istio` — or any non-empty string; the verifier checks the field is set, not the value.
   - One listener on port 80, protocol HTTP.

2. An **`HTTPRoute`** (`gateway.networking.k8s.io/v1`, or `v1beta1`) named `web-route`:
   - `parentRefs` pointing to the Gateway `dojo-gw` in the same namespace.
   - One rule: match path prefix `/` (or any host/path combination) with a `backendRef` targeting Service `web-svc` on port 80.

The verifier checks that both objects exist and are properly wired.

## Target state (what verify.sh checks)

1. A `Gateway` named `dojo-gw` exists in `dojo-gw`.
2. An `HTTPRoute` named `web-route` exists in `dojo-gw`.
3. The HTTPRoute has at least one `backendRef` referencing Service `web-svc`.
4. The HTTPRoute has at least one `parentRef` pointing to Gateway `dojo-gw`.

## Rules of engagement

- Work only in namespace `dojo-gw`.
- Use `kubectl apply -f` with YAML manifests — `kubectl create` does not support these CRD types.
- `kubectl explain httproute.spec.rules.backendRefs` is your friend.
- You may add hostname/path matchers beyond the minimum — the verifier does not constrain them.
