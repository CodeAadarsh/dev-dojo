# Building Resilience (What Chaos Validates)

> **Module 07 · Course 28** — Every chaos experiment you've run so far was testing something. This module names the things it was testing: the resilience patterns that separate systems that degrade gracefully from systems that fail completely. Timeouts, retries, circuit breakers, bulkheads, graceful degradation — each one is a bet about failure modes, and chaos is how you collect on the bet or discover it was wrong.

This is the module that ties the course together. You've broken pods, injected latency, pressured resources. Now you understand *why* those failures expose specific gaps, and *what to code and configure* to close each one.

---

## Timeouts — The Foundation Everything Else Builds On

A missing timeout is the single most common source of cascading failure in distributed systems. When Service A calls Service B and B hangs, A's thread (or goroutine, or connection-pool slot) is held open indefinitely. Under load, A exhausts all its workers waiting for B. Now A is down too — not because of its own bug, but because B was slow.

```
Service A → Service B (hanging, 30s+ response)

t=0s:   A has 100 goroutines. 1 is waiting on B.
t=10s:  10 goroutines waiting on B. 90 free.
t=30s:  30 goroutines waiting on B. 70 free.
t=60s:  100 goroutines waiting on B.  0 free.
        New requests to A start failing.
        A is down. B caused it; A owns no bugs.
```

**Two distinct timeouts, both required:**

| Timeout | What it limits | Typical value |
|---------|---------------|---------------|
| **Connect timeout** | Time to establish the TCP connection | 1–3s |
| **Read timeout** | Time to receive the response after connection | SLO-dependent, e.g., 5s |

Setting only a read timeout doesn't protect against a DNS timeout or a network black hole that never completes the TCP handshake. Set both.

```go
// Go http.Client with both timeouts
client := &http.Client{
    Timeout: 5 * time.Second,  // total deadline, connect + read
    Transport: &http.Transport{
        DialContext: (&net.Dialer{
            Timeout:   2 * time.Second,  // connect timeout
            KeepAlive: 30 * time.Second,
        }).DialContext,
        ResponseHeaderTimeout: 5 * time.Second, // read timeout
    },
}
```

```python
# Python requests with both timeouts: (connect_timeout, read_timeout)
response = requests.get(url, timeout=(2.0, 5.0))
```

### Kubernetes-level timeout layering

Timeouts exist at multiple layers and they must be consistent:

```
Client (10s total deadline)
    → Ingress / Gateway (proxy_read_timeout 15s — must be > client timeout)
        → Service mesh sidecar (request timeout 8s)
            → App code HTTP client (5s read timeout)
                → Downstream service
```

If the Nginx ingress has `proxy_read_timeout 60s` and your app client times out in 5s, the ingress will hold the connection open for 55 more seconds after your app already gave up. Configure from outermost to innermost: outer timeouts must be greater than inner timeouts.

```yaml
# Ingress timeout annotation (nginx ingress controller)
annotations:
  nginx.ingress.kubernetes.io/proxy-connect-timeout: "5"
  nginx.ingress.kubernetes.io/proxy-read-timeout: "15"
  nginx.ingress.kubernetes.io/proxy-send-timeout: "15"
```

> **Chaos validation.** Run a NetworkChaos `delay` experiment injecting latency above your timeout threshold. Your readinessProbe should detect the service health degradation and remove the pod from Service endpoints. Your client timeout should fire before threads are exhausted. If either doesn't happen, you found a gap.

---

## Retries + Backoff + Jitter

A retry without backoff is a DDoS against a service that's already struggling. When 1000 clients all retry at the exact same moment after a transient failure, they create a thundering herd that guarantees the downstream stays down.

### Exponential backoff formula

```
delay(attempt) = min(base × 2^attempt, max_delay)

attempt 1: min(100ms × 2^1, 30s) = 200ms
attempt 2: min(100ms × 2^2, 30s) = 400ms
attempt 3: min(100ms × 2^3, 30s) = 800ms
attempt 4: min(100ms × 2^4, 30s) = 1600ms
...
attempt 9: min(100ms × 2^9, 30s) = 30000ms (cap hit)
```

### Jitter — the part everyone skips

Without jitter, all retrying clients synchronise. After a 2-second outage, every client that timed out at t=2s retries at t=2.0s, t=2.2s, t=2.4s... all together. Jitter desynchronises the retry wave:

```
delay(attempt) = random_between(0, min(base × 2^attempt, max_delay))
```

The simplest correct implementation (full jitter):

```python
import random, time

def retry_with_backoff(fn, max_attempts=5, base_ms=100, max_ms=30000):
    for attempt in range(max_attempts):
        try:
            return fn()
        except TransientError as e:
            if attempt == max_attempts - 1:
                raise
            cap = min(base_ms * (2 ** attempt), max_ms)
            delay_ms = random.uniform(0, cap)
            time.sleep(delay_ms / 1000)
```

### What to retry and what not to

```
RETRY:   connection errors, timeouts, 429, 503, 502
NO-RETRY: 400, 401, 403, 404, 422 — these won't improve with repetition
IDEMPOTENCY: only retry non-mutating operations, or operations with idempotency keys
```

Retrying a `POST /payment` without an idempotency key will charge the customer twice. This is a data correctness bug masquerading as a resilience feature.

```yaml
# Istio VirtualService: retry policy with backoff (service mesh layer)
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: web-vs
  namespace: dojo-chaos
spec:
  hosts:
    - web
  http:
    - retries:
        attempts: 3
        perTryTimeout: 2s
        retryOn: "connect-failure,refused-stream,503"
      timeout: 8s
      route:
        - destination:
            host: web
```

> **Chaos validation.** Inject 30% packet loss with NetworkChaos. Watch your client's retry metrics. Do success rates hold? Does latency increase linearly with retry count (backoff working) or stay flat (no backoff, retrying at full speed)? Are there any idempotency violations in your application logs?

---

## Circuit Breakers

A circuit breaker wraps a call to a downstream service and tracks its failure rate. When failures exceed a threshold, the breaker *opens* — subsequent calls fail immediately without hitting the downstream at all. After a cooldown, it enters *half-open* and lets a probe request through. If that succeeds, it closes.

```
CLOSED          → normal operation, failures tracked
    failure_rate > threshold → OPEN
OPEN            → fail-fast, no downstream calls
    after cooldown → HALF-OPEN
HALF-OPEN       → one probe request
    probe success → CLOSED
    probe fail    → OPEN (reset cooldown)
```

**Without a circuit breaker:** when downstream B is overloaded, every call from A reaches B, adding more load, preventing recovery. A is stuck waiting.

**With a circuit breaker:** when B is failing, A stops calling it immediately. B gets zero additional load. B recovers faster. A starts recovering too.

```yaml
# Istio DestinationRule: outlier detection (circuit breaker in the mesh)
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: db-circuit-breaker
  namespace: dojo-chaos
spec:
  host: db
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 50
      http:
        http1MaxPendingRequests: 100
        http2MaxRequests: 200
    outlierDetection:
      consecutive5xxErrors: 5       # open after 5 consecutive 5xx
      interval: 10s                 # evaluation window
      baseEjectionTime: 30s         # how long to stay open
      maxEjectionPercent: 100
      minHealthPercent: 0
```

> **The circuit breaker doesn't replace retries — it composes with them.** Retry a request up to 3 times (with backoff). If the circuit breaker is open, the retry fails fast on all three attempts. The circuit breaker protects the downstream from the retry storm.

---

## Bulkheads

A bulkhead isolates a pool of resources so that failure in one area can't drain resources from others. Named after the watertight compartments in a ship hull: if one floods, the others stay dry.

### Thread pool / worker pool bulkhead

```
Without bulkhead:
Service A has a single thread pool of 100 workers.
Slow call to Service B holds 80 workers.
All calls to Service C also queue behind the 20 remaining.
Service C is healthy but unreachable because B is slow.

With bulkhead:
Pool for B: 40 workers max
Pool for C: 40 workers max
Pool for D: 20 workers max
B being slow fills its pool, C and D are unaffected.
```

In Kubernetes terms, bulkheads apply at multiple levels:

```yaml
# Connection pool limit per downstream (Istio DestinationRule)
spec:
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 25      # cap connections to this service
      http:
        http1MaxPendingRequests: 50
        maxRequestsPerConnection: 5  # force connection recycling
```

```yaml
# ResourceQuota per namespace: namespace A's runaway pod can't starve namespace B
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-quota
  namespace: dojo-chaos
spec:
  hard:
    requests.cpu: "2"
    requests.memory: "2Gi"
    pods: "10"
```

Bulkheads at the Kubernetes namespace level mean one team's noisy deployment can't OOM-evict another team's pods — provided the ResourceQuota is set on both namespaces.

---

## Graceful Degradation

A service that degrades gracefully provides reduced functionality rather than complete failure. The design question is: *what is the minimum viable response for each dependency being unavailable?*

```
Normal path:    request → fetch from DB → enrich with recommendations → return
DB unavailable: request →   (DB circuit open)  → return cached stale data
Recs unavailable: request → DB result → (recs timeout) → return DB result without enrichment
Both unavailable: request → return stale cached response + "data may be delayed" flag
```

```python
def get_product(product_id: str) -> dict:
    # Try primary DB
    try:
        product = db_client.get(product_id, timeout=2.0)
    except (TimeoutError, CircuitOpenError):
        product = cache.get(f"product:{product_id}")  # stale read
        if not product:
            raise ServiceUnavailableError("product data unavailable")

    # Enrich with recommendations — best effort, never fail the request
    try:
        recs = rec_service.get(product_id, timeout=1.0)
        product["recommendations"] = recs
    except Exception:
        product["recommendations"] = []  # degraded but not broken

    return product
```

**Feature flags as circuit breakers for features.** A feature flag in your config lets you disable a non-critical dependency path without a deploy:

```yaml
# ConfigMap used as a feature flag store
apiVersion: v1
kind: ConfigMap
metadata:
  name: feature-flags
  namespace: dojo-chaos
data:
  recommendations_enabled: "false"   # flip this during a dependency incident
  enrichment_timeout_ms: "1000"
```

```bash
# During an incident: disable recommendations without a deploy
kubectl -n dojo-chaos patch configmap feature-flags \
  --type=merge -p '{"data":{"recommendations_enabled":"false"}}'
```

> **Chaos validation.** Inject a NetworkChaos `partition` between your service and its enrichment dependency. Does the service return 200 with a degraded response, or does it return 500? If it returns 500 for a non-critical enrichment failure, you found a missing graceful-degradation path.

---

## Redundancy and Multi-Zone Spread

No resilience pattern compensates for a single replica in a single availability zone. Redundancy is the prerequisite; everything else is optimization.

### PodTopologySpreadConstraints

Spread replicas across zones and nodes so a single node failure can't take down a quorum:

```yaml
spec:
  replicas: 3
  template:
    spec:
      topologySpreadConstraints:
        - maxSkew: 1                              # max difference in pods between zones
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule        # hard constraint
          labelSelector:
            matchLabels:
              app: web
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname     # also spread across nodes
          whenUnsatisfiable: ScheduleAnyway       # soft constraint — don't block scheduling
          labelSelector:
            matchLabels:
              app: web
```

### Pod Anti-Affinity (for kind clusters without real zones)

```yaml
spec:
  template:
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: web
              topologyKey: kubernetes.io/hostname
          # hard: never two web pods on the same node
```

With 3 replicas and hard anti-affinity, a single node failure takes out at most 1 of 3 replicas. With a PDB of `minAvailable: 2`, a voluntary drain also can't take out more than 1 at a time.

```
3 nodes, 3 replicas, PDB minAvailable=2:
Node 1: web-pod-1   Node 2: web-pod-2   Node 3: web-pod-3
    Node 1 fails → 2 pods left → PDB satisfied, service continues
    Drain Node 2 → blocked until web-pod-3 is Ready on a new node
```

---

## Observing Resilience During Chaos

When a chaos experiment is running, know which metrics to watch:

```
Golden signals to observe during fault injection:
───────────────────────────────────────────────
1. Error rate         — requests returning 5xx / total requests
2. Latency p99        — the tail, not the average
3. Saturation         — CPU throttle ratio, memory usage % of limit
4. Traffic            — RPS; a drop can mean the service is down, not recovered

Kubernetes-specific signals:
5. Restart count      — kubectl get pods: RESTARTS column
6. Ready replicas     — kubectl get deploy -o wide
7. HPA events         — kubectl get events | grep Horizontal
8. Endpoint changes   — kubectl get endpoints <service-name> -w
```

```bash
# Live multi-signal view during a chaos experiment:
watch -n 2 'kubectl -n dojo-chaos get pods; \
  echo "---"; \
  kubectl -n dojo-chaos get deploy -o wide; \
  echo "---"; \
  kubectl -n dojo-chaos get endpoints web'
```

The endpoint count is underused as a signal. When readiness probes start failing under load, pods are removed from endpoints. Watching `kubectl get endpoints web -w` shows you the probe-driven traffic exclusion in real time — often before any error rate hits your dashboards.

---

## Debugging Resilience Failures

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| One slow downstream takes down the entire service | Missing or infinite timeout on the downstream call | Add connect + read timeout; verify under NetworkChaos delay injection |
| Retry storm during an outage makes recovery slower | Retries with no backoff or jitter — all clients retry in sync | Implement exponential backoff with full jitter; add per-client retry budget |
| Service A is down but Service B (the cause) recovered | A's circuit breaker is open and never re-probed | Check circuit breaker config — `baseEjectionTime` may be too long; check half-open probe behavior |
| Mutating endpoint returns duplicate records after retry | Retry applied to a non-idempotent operation | Add idempotency keys; do not retry POST/PUT without them; retry only GET and idempotent ops |
| Dependent service outage returns 500 instead of degraded 200 | Missing graceful degradation path — all errors surface as failures | Add try/except for each non-critical dependency; return partial response with a degraded flag |
| All replicas on one node; node failure takes service to zero | No topology spread or anti-affinity | Add `podAntiAffinity` (hard, on `kubernetes.io/hostname`) or `topologySpreadConstraints` |
| PDB blocks drain but service is still under-replicated during maintenance | `minAvailable` too high relative to replica count, blocking all progress | Set `minAvailable` to `replicas - 1`, or use `maxUnavailable: 1` instead |
| Chaos experiment ends, but latency stays elevated | Dependent service didn't recover — circuit breaker never closed | Check downstream health independently; force circuit half-open or restart the sidecar proxy |

> **War story.** We had a recommendations microservice that was explicitly non-critical — tagged as optional in our architecture diagram, with a documented fallback path in the design doc. During a chaos experiment (pod kill on the recs service), the main product API's error rate jumped to 40%. We'd assumed the fallback was coded. It wasn't. The original author had written `return recs_client.get(...)` with no try/except and no timeout. The design doc described the intended fallback; the code never implemented it. The chaos experiment found it in staging in 8 minutes. If we'd run it in production first during a real incident, we'd have had a 40% error rate for the duration of a recommendations service outage — which happens about twice a quarter. The fix was 12 lines of Python: a try/except with a 1-second timeout and a `return []` fallback. The lesson: **"non-critical dependency" is an architectural claim, not a code property. Chaos engineering is how you verify the code actually matches the architecture.** File a ticket for every divergence. The divergence between the design doc and the code had existed for 14 months before we found it.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Explain why a missing timeout on a downstream call causes cascading failure, with a concrete thread-pool depletion example.
2. Write the full jitter exponential backoff formula and explain why jitter is necessary, not optional.
3. State the three states of a circuit breaker and the transition conditions between them.
4. Name two operations you should never retry without an idempotency key and explain why.
5. Describe a concrete graceful degradation path for a service whose enrichment dependency goes down, and write the Python/Go try/except pattern.
6. Write a `topologySpreadConstraints` spec that keeps 3 replicas spread across 3 zones with hard constraints on zones and soft constraints on nodes.
7. During a live chaos experiment, which Kubernetes object tells you how many pods are receiving traffic in real time, and what is the command to watch it?
8. Explain the war story gap: the design doc described a fallback but the code didn't have one. What is the only process that reliably detects this class of divergence before production?

➡ You've completed Course 28 — Chaos Engineering. The next step is to take these patterns to the challenges: inject real faults into a running cluster, write the assertions that prove resilience, and earn the flags.
