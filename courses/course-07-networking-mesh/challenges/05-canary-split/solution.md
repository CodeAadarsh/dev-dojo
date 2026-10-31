# Solution — Canary Traffic Split

Two manifests: a `DestinationRule` defining the v1/v2 subsets, and a `VirtualService` assigning the 90/10 weights.

```yaml
# destination-rule.yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: app
  namespace: dojo-canary
spec:
  host: app
  subsets:
    - name: v1
      labels:
        version: v1
    - name: v2
      labels:
        version: v2
---
# virtual-service.yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: app
  namespace: dojo-canary
spec:
  hosts:
    - app
  http:
    - route:
        - destination:
            host: app
            subset: v1
          weight: 90
        - destination:
            host: app
            subset: v2
          weight: 10
```

Apply and verify:

```bash
kubectl apply -f destination-rule.yaml -f virtual-service.yaml
bash courses/course-07-networking-mesh/challenges/05-canary-split/verify.sh
```

## Why each piece matters

**`DestinationRule` is the identity layer.** It tells Envoy how to subdivide the pods behind a Service. Without it, the `VirtualService` has no named subsets to reference — you'd get a 503 from the sidecar. The subset `labels` must match pod labels *exactly* as stored in the Deployment template; a mismatch silently routes 0 traffic.

**`VirtualService` is the traffic policy layer.** It intercepts all HTTP traffic from the mesh hitting host `app` and applies the weighted routing. Weights must sum to exactly 100 — Istio validates this at admission time (with a validating webhook) and rejects the manifest otherwise.

**The order of apply matters.** Apply the `DestinationRule` first. If you apply only the `VirtualService`, Envoy will try to use the subsets and fail with a 503 until the `DestinationRule` catches up. In GitOps (Argo/Flux), the common fix is to apply both in the same sync wave or ensure the DR has a lower `sync-wave` annotation.

## Proving it works

From a throwaway pod inside the mesh, loop a few hundred requests and count how many hit v2:

```bash
kubectl run -n dojo-canary --rm -it probe --image=nicolaka/netshoot -- \
  sh -c 'for i in $(seq 1 100); do curl -s http://app/; done' | grep -c v2-response
# Expect ~10 out of 100
```

Real canary workflows layer on top of this: a Flagger `Canary` object (or Argo Rollouts `Rollout`) automates the weight progression based on Prometheus metrics — once the error rate and latency on v2 look clean, it steps the weight from 10 → 30 → 70 → 100 automatically and rolls back if a threshold is breached.

## Attacker's view / hardening

A `VirtualService` with header-based routing lets an attacker (with access to set request headers) force all their traffic to v2 — useful for targeted testing but dangerous if `v2` has weaker auth. Pair this with an `AuthorizationPolicy` that restricts which service accounts can reach each subset.
