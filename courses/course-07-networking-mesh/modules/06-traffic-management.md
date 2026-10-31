# Traffic Management

> **Module 06 · Course 07** — A new binary lands. You need to send 5% of live traffic to it, watch the error rate, and roll back in under 30 seconds if anything goes wrong. Without a mesh: re-deploy, fiddle with Service selectors, pray. With a mesh: edit a percentage in a YAML file and apply it. This module covers the Istio primitives — VirtualService, DestinationRule, and the Gateway API alternative — that make canary releases, circuit breakers, and chaos testing a configuration problem instead of a code problem.

This is where mesh investment pays off. The primitives here are load-bearing in production: canary weights that have saved countless Sunday-evening rollbacks, retry configs that paper over transient infra glitches, and circuit breakers that limit blast radius when a downstream goes sideways.

---

## The two objects: VirtualService and DestinationRule

Every Istio traffic management feature combines two objects:

| Object | Answers | Think of it as |
|--------|---------|----------------|
| `VirtualService` | *How is traffic routed?* Weights, retries, timeouts, faults, mirroring | The routing table |
| `DestinationRule` | *How do we connect to an upstream?* Subsets (versions), TLS mode, load balancing, circuit breaking | The connection policy |

They are orthogonal: routing decisions and connection behavior are separated on purpose. You can apply a VirtualService weight split without a DestinationRule (Istio uses default connection settings), and you can set circuit breaking in a DestinationRule without a VirtualService routing rule.

```bash
kubectl -n dojo-mesh get virtualservice
kubectl -n dojo-mesh get destinationrule
```

---

## Canary deployment via weighted routing

A canary release routes a small percentage of live traffic to the new version while keeping most traffic on the stable version, with a fast rollback path.

**Step 1: Label your versions.** Both Deployments share the same `app` label so the Service selects them both. A `version` label distinguishes them:

```yaml
# stable Deployment (v1)
spec:
  selector:
    matchLabels:
      app: api
      version: v1
  template:
    metadata:
      labels:
        app: api
        version: v1

# canary Deployment (v2) — separate object, same Service selector on app: api
spec:
  selector:
    matchLabels:
      app: api
      version: v2
  template:
    metadata:
      labels:
        app: api
        version: v2
```

**Step 2: Define subsets in a DestinationRule.**

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: api
  namespace: dojo-mesh
spec:
  host: api
  subsets:
    - name: v1
      labels:
        version: v1
    - name: v2
      labels:
        version: v2
```

**Step 3: Distribute traffic with a VirtualService.**

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: api
  namespace: dojo-mesh
spec:
  hosts:
    - api
  http:
    - route:
        - destination:
            host: api
            subset: v1
          weight: 90
        - destination:
            host: api
            subset: v2
          weight: 10
```

Shifting the canary means editing the weights and reapplying. No pod restarts. No Service changes. The weights must sum to 100; Envoy enforces this at admission time.

```bash
# Verify the split is active (dump the effective route config seen by a sidecar)
istioctl proxy-config route <pod>.<ns> -o json | grep -A10 'weighted_clusters'

# Watch live traffic distribution via Envoy stats
kubectl exec -it <pod> -n dojo-mesh -c istio-proxy -- \
  pilot-agent request GET stats | grep upstream_rq_total
```

---

## Blue-green deployment

Blue-green = instant cutover between two live versions, with both running simultaneously until confidence in v2 is high enough to decommission v1:

```yaml
# Cut over: v2 gets 100%, v1 stays running for fast rollback
http:
  - route:
      - destination:
          host: api
          subset: v2
        weight: 100
      - destination:
          host: api
          subset: v1
        weight: 0
```

Rollback in under 30 seconds: swap the weights back and `kubectl apply`. No new image, no rollout, no drain. After v2 proves stable at 100%, scale down the v1 Deployment (`kubectl scale deploy api-v1 --replicas=0`). Blue-green is preferred when you want strict version isolation and a clean, instantaneous cutover rather than a gradual ramp.

---

## Retries

Retries absorb transient failures — a pod restarting mid-request, a 503 flash during a rolling update — by retrying before returning an error to the caller.

```yaml
http:
  - route:
      - destination:
          host: api
          subset: v1
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: 5xx,gateway-error,connect-failure,retriable-4xx
```

**The idempotency rule.** Only retry requests safe to repeat. GET and HEAD: safe. POST, PATCH, DELETE: only safe if the upstream implements deduplication (idempotency keys). Blind retries on non-idempotent endpoints cause duplicate writes, duplicate charges, duplicate emails. The `retryOn` field accepts an enum from Envoy's docs; the set above covers transient infra failures without retrying logical application errors like 400 Bad Request.

**Worst-case latency.** `perTryTimeout × attempts` is the ceiling before a failure reaches the caller: 3 × 2s = 6s. If your SLA is 3s end-to-end, set `perTryTimeout: 1s, attempts: 2` and add an overall `timeout: 2s` ceiling to cap the whole operation.

---

## Timeouts

Set per-route in VirtualService:

```yaml
http:
  - route:
      - destination:
          host: db-svc
          subset: primary
    timeout: 5s
```

A route-level `timeout` is the ceiling on the entire operation including retries. If `timeout: 5s` and `perTryTimeout: 2s` with `attempts: 3`, the first two retry attempts take at most 4s, and the third attempt gets the remaining 1s ceiling — not the full `perTryTimeout: 2s`.

The correct mental model for a service graph is a **decreasing timeout budget**:

```
edge gateway (10s)  →  aggregator (7s)  →  leaf service (4s)
```

Each downstream service gets a smaller timeout than its caller. This ensures the caller always times out *after* the callee, so you get a clean error propagation rather than a cascade where every service simultaneously retries at the worst moment.

---

## Circuit breaking

Circuit breaking stops sending requests to an unhealthy upstream. Instead of queuing requests that will time out, Envoy ejects the failing host from the load-balancing pool. This protects the caller from accumulating latency and gives the upstream time to recover.

Circuit breaking lives in `DestinationRule` (it's a connection policy, not a routing rule):

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: api-cb
  namespace: dojo-mesh
spec:
  host: api
  trafficPolicy:
    connectionPool:
      http:
        http1MaxPendingRequests: 100
        http2MaxRequests: 1000
      tcp:
        maxConnections: 100
    outlierDetection:
      consecutiveGatewayErrors: 5    # eject after 5 consecutive 5xx/gateway errors
      interval: 30s                  # check hosts every 30s
      baseEjectionTime: 30s          # ejected host stays out for 30s minimum
      maxEjectionPercent: 50         # never eject more than 50% of hosts at once
```

`outlierDetection` is Envoy's circuit breaker. When a host hits `consecutiveGatewayErrors` 5xx responses in a row, Envoy ejects it from rotation for `baseEjectionTime`. After ejection, it gets a probe request; success re-admits it.

`maxEjectionPercent: 50` is a safety valve. Without it, if every replica is failing simultaneously, Envoy could eject all of them and turn the circuit breaker into a complete blackhole. Capping at 50% means at least half the pool stays in rotation even under total failure.

---

## Fault injection

Fault injection introduces latency or errors on purpose — the fastest way to verify that your retry and timeout config actually works before it matters in production.

```yaml
http:
  - fault:
      delay:
        percentage:
          value: 10.0     # 10% of requests get an injected delay
        fixedDelay: 3s
      abort:
        percentage:
          value: 5.0      # 5% of requests get an injected 503
        httpStatus: 503
    route:
      - destination:
          host: api
          subset: v1
```

No application code changes. No network partition. Apply this VirtualService, run your load test, and confirm your retries are firing and your latency SLO holds. Remove the fault block when done.

```bash
# Confirm the fault rule is active in the sidecar's route config
istioctl proxy-config route <pod>.<ns> -o json | grep -A5 fault

# Drive traffic and observe the injected errors
kubectl run test --rm -it --restart=Never \
  --image=nicolaka/netshoot:v0.13 -- \
  bash -c 'for i in $(seq 1 30); do curl -s -o /dev/null -w "%{http_code}\n" http://api.dojo-mesh.svc.cluster.local:8080/; done'
```

---

## Traffic mirroring (shadowing)

Mirroring sends a copy of live traffic to a secondary destination. The caller only waits for the primary response; the mirror's response is discarded. Use it to validate v2 against real production-shaped traffic without exposing users to it:

```yaml
http:
  - route:
      - destination:
          host: api
          subset: v1
        weight: 100
    mirror:
      host: api
      subset: v2
    mirrorPercentage:
      value: 100.0    # mirror all requests; use 10.0 for high-volume services
```

v2 receives real requests with real payloads and real timing characteristics. Its responses are discarded — users see only v1's responses. Mirroring is a read-path validation tool. If v2 has write semantics (database mutations, emails, external API calls), mirror carefully or not at all.

---

## Gateway API as an alternative

Istio's VirtualService and DestinationRule are proprietary CRDs. The SIG Network Gateway API provides a portable set (`HTTPRoute`, `Gateway`, `GatewayClass`) implemented by Istio, Envoy Gateway, Cilium, and others:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api-canary
  namespace: dojo-mesh
spec:
  parentRefs:
    - name: mesh
      kind: Gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: api-v1
          port: 8080
          weight: 90
        - name: api-v2
          port: 8080
          weight: 10
```

Notable difference: Gateway API's `backendRefs` point directly to Services (not to DestinationRule subsets). The `weight` field is on the backendRef. Retries, timeouts, and header manipulation live in `HTTPRoute` filters. Circuit breaking is still an Envoy-layer concern expressed via annotations or vendor-specific CRDs.

If you are starting a new mesh installation today, evaluate Gateway API alongside VirtualService. It is the long-term direction for Kubernetes networking, and Istio supports both in parallel.

---

## Debugging Traffic Management

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Weight split applied but traffic all goes to one subset | DestinationRule `subset.labels` don't match pod labels exactly | `kubectl -n <ns> get pods --show-labels` and compare to subset label selectors |
| 50/50 split configured but long-lived connections go to one pod | HTTP/2 or gRPC connections are multiplexed; weights apply per-connection, not per-request | Add `loadBalancer: ROUND_ROBIN` in DestinationRule `trafficPolicy`; or test with short-lived HTTP/1.1 |
| Retries fire but errors still spike — retry storm | `retryOn` too broad, retrying non-idempotent requests, amplifying load on the failing upstream | Narrow `retryOn`; add circuit breaking to eject the failing host; add a `timeout` ceiling on the operation |
| Timeout cascades: caller times out before getting a response from callee | Caller timeout is shorter than callee timeout + callee retry budget | Ensure timeout budget is monotonically decreasing upstream to downstream; correlate spans in Jaeger |
| VirtualService has no effect on traffic | `hosts` field doesn't match the Kubernetes Service name exactly | Check short name vs FQDN; run `istioctl analyze -n dojo-mesh` for misconfiguration lint |
| Fault injection not triggering | `percentage.value` parsed wrong (e.g. `100` vs `100.0`) | Use float explicitly; verify with `istioctl proxy-config route <pod>.<ns>` |
| Circuit breaker opens but traffic goes to blackhole (all 503) | `maxEjectionPercent: 100` allows ejecting all hosts simultaneously | Set `maxEjectionPercent` to 50 or lower to keep a floor in rotation |

### Exact debugging commands

```bash
# Is the weight split visible in the sidecar's routing config?
istioctl proxy-config route <pod>.<ns> -o json | grep -A15 weighted_clusters

# Which endpoints does the proxy know for a service?
istioctl proxy-config endpoint <pod>.<ns> | grep <svc>

# Check upstream request counters (is traffic actually flowing to each subset?)
kubectl exec -it <pod> -n dojo-mesh -c istio-proxy -- \
  pilot-agent request GET stats | grep upstream_rq

# Count retry events
kubectl exec -it <pod> -n dojo-mesh -c istio-proxy -- \
  pilot-agent request GET stats | grep upstream_rq_retry

# Lint the full mesh config
istioctl analyze -n dojo-mesh --all-namespaces

# Trace a single request end-to-end via Envoy logs
kubectl logs -f <pod> -n dojo-mesh -c istio-proxy \
  | grep '"response_code":"503"'
```

### Diagnose retry storms

A retry storm amplifies load on an already-struggling upstream. Symptom: a service handling 1,000 RPS starts receiving 3,000 RPS from a single caller configured with `attempts: 3`, making the overload worse, causing more 5xx, causing more retries.

```bash
# Watch upstream_rq_retry grow relative to upstream_rq_total
kubectl exec -it <pod> -n dojo-mesh -c istio-proxy -- \
  pilot-agent request GET stats \
  | grep -E 'upstream_rq_total|upstream_rq_retry'
# High retry:total ratio (>20%) = retry storm
```

Remedies: reduce `attempts` to 2, add a `timeout` ceiling so retries can't run indefinitely, add `outlierDetection` to eject the failing host instead of retrying into it, narrow `retryOn` to exclude `503` when the upstream is circuit-broken.

### Diagnose timeout cascades

A cascade occurs when a service's overall timeout is longer than its upstream's `perTryTimeout × attempts` budget. The upstream exhausts its retry budget and returns an error; the caller retries (because 503 is in `retryOn`); by the time the caller's own timeout fires, it has burned its entire budget and returned late.

```bash
# Correlate span durations in Jaeger (port-forward if needed)
kubectl -n istio-system port-forward svc/tracing 16686:80

# Cross-check timeout config on every service in the call chain
kubectl -n dojo-mesh get virtualservice -o yaml \
  | grep -A3 timeout
```

The fix: enforce a decreasing timeout budget through the call chain (edge > aggregator > leaf), and use distributed tracing to verify where time is actually spent before setting numbers in YAML.

> **War story.** A payment processor service was configured with `retryOn: 5xx` and `attempts: 3`. Load testing revealed that a 10% error rate on the checkout service produced a 30% surge on the payment service — 3x amplification. Worse: when the payment service's own circuit breaker opened (returning 503), `retryOn: 5xx` matched and checkout retried those too — retrying into an already-circuit-broken service. `maxEjectionPercent` was set to 100, so Envoy could eject every payment instance simultaneously, turning circuit breaking into a complete outage. The fix was three changes applied together: set `maxEjectionPercent: 50`, narrow `retryOn` to exclude `503` from the circuit-broken upstream (use `connect-failure,reset,retriable-4xx`), and add `timeout: 6s` as a hard ceiling so retries can't accumulate beyond the SLA. Load-test first, tune in staging, deploy with a canary split — in that order.

---

## Checkpoint

You are ready to move on when you can:

1. Write a VirtualService sending 10% of traffic to v2, 90% to v1, with 2 retry attempts on 5xx.
2. Explain why retries amplify load on a failing upstream and name two safeguards.
3. Distinguish `VirtualService timeout` (routing) from `DestinationRule outlierDetection` (connection policy).
4. Write a DestinationRule with circuit breaking and explain what `maxEjectionPercent` prevents.
5. Explain what traffic mirroring does and why it's unsafe for write-path testing.
6. Diagnose "weights applied, traffic still goes to one subset" in two steps.
7. Name the portable alternative to Istio VirtualService and explain why it matters for long-term portability.

➡ This completes the Networking & Service Mesh track. The next course covers production hardening — admission controllers, OPA/Kyverno policy, and supply chain security.
