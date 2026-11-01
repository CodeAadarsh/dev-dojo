# Failure Modes & the Fault Model

> **Module 02 · Course 28** — Chaos engineering without a fault taxonomy is guesswork. You need to know *what kind* of failure you're injecting before you can predict its blast radius, choose the right tool, and interpret the results. This module builds the vocabulary and the map.

You already know how to define a hypothesis (Module 01). Now you need to know what you're hypothesizing *about*.

---

## Why taxonomy matters

Not all failures look alike. A pod that crashes immediately is a fail-stop event; Kubernetes has strong built-in responses for it and your monitoring will catch it inside 10 seconds. A pod that responds slowly but returns incorrect data can keep traffic flowing while silently corrupting state for hours. A dependency that drops every fifth request is invisible to P50 metrics while destroying P99.

Before injecting any fault, you should be able to answer:
- What *category* of failure is this?
- Will my monitoring detect it, or will it look like "intermittent slowness"?
- Where does redundancy help, and where does it make things worse?

---

## The four classical failure types

The distributed systems literature (Lamport, Fischer, Lynch) converges on four categories:

### 1. Crash (fail-stop)

The process stops responding entirely. It does not lie, delay, or corrupt — it simply goes away. Crash faults are the *easiest* to handle because they are immediately detectable: `kubectl get pods` shows `CrashLoopBackOff` or `Terminating`, health checks fail, liveness probes time out.

```bash
# Crash fault injection: kill a pod forcibly
kubectl delete pod -n dojo-chaos-pod <podname> --force --grace-period=0

# Or send SIGKILL to PID 1 inside the container:
kubectl exec -n dojo-chaos-pod <podname> -- kill -9 1
```

Redundancy (replica count > 1, PDB) **directly** mitigates crash faults. This is the failure type that more replicas were designed to handle.

### 2. Omission (drop)

The node is alive but silently drops some or all requests. The process appears healthy — its own health endpoint responds — but requests disappear. Omission faults are harder to detect because you must instrument the *call site*, not just the service.

```bash
# Omission simulation: drop all TCP packets to port 8080 from the worker node
docker exec dojo-worker iptables -A OUTPUT -p tcp --dport 8080 -j DROP

# Cleanup:
docker exec dojo-worker iptables -D OUTPUT -p tcp --dport 8080 -j DROP
```

A readiness probe that uses the same port as the dropped rule will itself be dropped — which is correct behavior. A probe on a *different* port will pass, making the pod look healthy while requests fail. This is a real misconfiguration pattern.

### 3. Timing (slow / response after deadline)

The node is alive and does respond, but does so slowly enough that clients time out or the response arrives too late for the business flow to succeed. Timing faults are the *most common real-world failure* and the most dangerous for retry-heavy systems.

```bash
# Timing fault: 500ms latency on eth0 of a kind worker node
docker exec dojo-worker tc qdisc add dev eth0 root netem delay 500ms

# Verify the qdisc is set:
docker exec dojo-worker tc qdisc show dev eth0

# Cleanup:
docker exec dojo-worker tc qdisc del dev eth0 root
```

The classic timing trap: a 30s timeout looks safe in isolation. Under a timing fault, 40 concurrent clients all wait 30s, exhausting the thread pool — and the upstream now sees a crash fault from its perspective. The timing fault *manifested as* an omission at the boundary.

### 4. Byzantine (arbitrary / wrong)

The node is alive, responds within the time window, but returns incorrect or inconsistent results. Byzantine faults require *comparison* to detect: multiple replicas must agree, or the client must validate the response body.

Kubernetes workloads rarely experience pure Byzantine faults, but partial Byzantine behavior is common:
- A pod returns HTTP 200 with a truncated or corrupted body (short read, encoding error)
- A pod's readiness probe passes but its DB connection pool is exhausted — it accepts the probe but rejects real requests
- Cached data is stale and silently wrong after a leader election

```
┌────────────────────────────────────────────────────────────────────┐
│          Fault Taxonomy vs Detection Difficulty                    │
│                                                                    │
│  Crash      ─── easy ────▶  liveness probe, pod restart count     │
│  Omission   ─── medium ──▶  client-side error rate, tracing       │
│  Timing     ─── medium ──▶  p99 latency, timeout counters         │
│  Byzantine  ─── hard ────▶  response validation, checksums, quorum│
│                                                                    │
│  Replica count helps most for:                                     │
│  Crash > Omission (per-pod) > Timing (per-pod) > Byzantine (not)  │
└────────────────────────────────────────────────────────────────────┘
```

---

## Dependency failure

Most production failures are not primary failures — they are secondary failures triggered by a dependency. Understanding how failure propagates across a dependency graph is what separates "the database is slow" from "the whole app is down."

```
API Gateway
    └── Orders Service ──── Inventory Service ─── PostgreSQL
             └── Payments Service ──── Stripe (external)
```

If PostgreSQL experiences a timing fault (slow queries), the causal chain is:

1. Inventory Service queries time out
2. Orders Service, waiting on Inventory, also times out
3. Orders Service thread pool is exhausted; new requests queue, then fail
4. API Gateway requests to Orders time out
5. API Gateway starts failing *all* requests — including ones that never touch Inventory

The blast radius of a PostgreSQL timing fault is the entire API gateway, even though PostgreSQL is two hops away. This is **fan-in amplification**: one slow dependency blocks all callers simultaneously.

```bash
# Inspect dependency relationships in a kind cluster via NetworkPolicies:
kubectl get networkpolicies -A -o yaml | grep -B2 -A10 'podSelector'

# Without a service mesh, trace ENV-var-based service discovery:
kubectl get pods -n dojo-chaos-net -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*].env[*]}{"\t"}{.name}{": "}{.value}{"\n"}{end}{end}'
```

---

## Gray failures

A gray failure is a failure that is *real but not fully visible* to standard monitoring. It typically affects a subset of traffic, a subset of replicas, or a specific time window.

Characteristics:
- Health checks pass (the pod is considered "healthy")
- Aggregate metrics look acceptable — P50 is fine; P99 is spiking but below the alert threshold
- Only affected users or affected requests experience the problem
- The failure may disappear under additional observation (the Heisenbug effect)

Examples in Kubernetes:
- A pod returns HTTP 200 but the response body is 60 bytes instead of 6 KB — truncated, but not an HTTP error
- A pod's readiness probe passes but its DB connection pool is exhausted; it accepts the probe on `/healthz` but fails every real request
- A CoreDNS TTL has expired but a Java runtime cached the old pod IP — 1 in 3 requests hit a dead endpoint while 2 succeed

```bash
# Detect gray failures: don't just check status codes — check response body sizes
for i in {1..100}; do
  curl -s http://web-svc.dojo-chaos-net/ | wc -c
done | sort | uniq -c

# Check for unexpected p99 variance:
wrk -t4 -c40 -d30s --latency http://web-svc.dojo-chaos-net/ 2>&1 | grep -E 'Latency|99%'

# Check pod connection pool exhaustion (app-specific; look for queue depth metrics or app logs):
kubectl logs -n dojo-chaos-net deploy/web --tail=50 | grep -iE 'pool|queue|waiting|timeout'
```

Gray failures are why steady-state hypotheses must use external, client-perspective signals. A service that "looks healthy from the inside" can be silently broken for users.

---

## Cascading failure & retry storms

A cascading failure is when a partial failure in one component causes *other components to fail*, eventually taking down far more than the initial blast radius.

The mechanism is almost always:
1. Service A gets slow (timing fault)
2. Callers of A time out and immediately retry
3. Retries increase load on A
4. A gets slower (or crashes entirely)
5. More retries, more load → feedback loop

This is the **retry storm**: exponential retries at scale amplify a timing fault into a crash fault. Without exponential backoff + jitter + circuit breakers, well-meaning retry logic is a reliability antipattern.

```
Without circuit breaker and backoff:
  t=0:  10 clients → Service A (slow, 1s response)
  t=1:  10 clients retry after 1s timeout → 20 concurrent requests
  t=2:  20 clients retry → 40 concurrent → Service A crashes
  t=3:  40 clients retry → circuit is wide open, total outage

With circuit breaker + exponential backoff + jitter:
  t=0:  10 clients → Service A (slow)
  t=1:  circuit opens on error threshold; clients fast-fail with a local error
  t=5:  circuit half-opens; one probe request succeeds
  t=6:  circuit closes; traffic restored
  # Total outage: ~5s instead of indefinite
```

Retry storms appear in Kubernetes when:
- A client library retries immediately without backoff
- A liveness probe triggers a pod restart right as the pod is receiving a queued backlog of retries
- HPA scales up new replicas that all connect to the same overloaded downstream simultaneously

---

## Where redundancy actually helps

More replicas is not a universal resilience dial.

| Failure type | Does replica count help? | Why |
|-------------|--------------------------|-----|
| Crash | Yes — directly | Other replicas absorb traffic; Deployment creates a replacement |
| Omission (per-pod) | Yes — partially | If omission is isolated to one pod's network path, other pods handle traffic |
| Omission (at load balancer or shared network) | No | All replicas are behind the same broken path |
| Timing (per-pod) | Yes — partially | Load balancer can route away from slow pods if health checks detect it |
| Timing (shared dependency) | No | All replicas hit the same slow DB or lock; more replicas increase load on the bottleneck |
| Byzantine | No, without consensus | All replicas may return wrong data; need quorum reads or checksums |
| Cascading / retry storm | Can make it worse | More replicas = more threads retrying the shared broken dependency |
| Gray failure | No | Health probes that determine "healthy replica" don't detect gray failures |

The implication: replica count is a crash-fault mitigation. Design for the fault model first; set replica count as the last line of defense, not the only line.

---

## Debugging: the SPOF you didn't know about

### Single points of failure

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Pod deletion kills the service despite 3 replicas | All pods landed on the same node; a node failure is a total outage | `kubectl get pods -o wide`; set `topologySpreadConstraints` with `whenUnsatisfiable: DoNotSchedule` so pods spread across nodes |
| 3/3 pods Ready but all requests fail | Shared dependency: every pod hits the same DB, the same external endpoint, or reads the same broken ConfigMap | `kubectl describe pod`, check volumes and env vars; trace the dependency graph — "all pods healthy" does not mean "all dependencies healthy" |
| Service goes down during a voluntary node drain | PDB exists but its selector doesn't match the deployment labels, so it's protecting nothing | `kubectl get pdb -n <ns> -o yaml` and verify `selector.matchLabels` exactly matches the pod labels; confirm with `kubectl get pdb` and check ALLOWED DISRUPTIONS |
| Feature works alone but breaks when two features run concurrently | Shared in-memory state or a lock held without a timeout | Add explicit timeouts to all lock acquisitions; use distributed locks (Redis, etcd) with TTLs; assume you will never hold a lock for longer than 1s |

### Retry amplification

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| One slow service causes all callers to have high CPU and thread exhaustion | Retries without backoff: each timed-out call retries immediately, doubling load each cycle | Configure `retry-after: exponential backoff, base=100ms, cap=30s, jitter=true` in every client that retries |
| HPA spins up 10× pods after a transient DB hiccup, then crashes the DB | New pods start immediately and drain queued retries toward the DB | Gate connections with a startup probe (`initialDelaySeconds`); set connection pool limits per pod; add a circuit breaker |
| 500% error spike for 90 seconds, then complete self-recovery | Retry storm passed; the storm ended only because the dependency recovered before being fully overwhelmed | Those 90 seconds consumed SLO budget; add a circuit breaker that fast-fails before the next incident reaches the same threshold |

> **War story.** On the AI Core log ingestion pipeline at SAP — 100GB+/day through Fluent Bit to Elasticsearch — we had naïve retries: 5 attempts, no delay between them. A 40-second ES index rotation (a timing fault, not a crash) triggered a storm: 5 retries × 3 Fluent Bit replicas = 15 simultaneous retry bursts every second against ES during its rotation window. ES buckled under write pressure and failed outright — the timing fault became a crash fault because of the retries. Fix: added exponential backoff (100ms → 200ms → 400ms → 800ms → 1600ms, 2s cap) plus `random.jitter()` in the retry loop. The same ES rotation now produces a brief P99 spike and never a full outage. That change was four lines of config. The lesson: retry policy is a first-class resilience control, as important as replica count.

---

## Checkpoint

You're ready for fault injection when you can, without looking anything up:

1. Name the four classical failure types and give one concrete Kubernetes example of each.
2. Explain how a PostgreSQL timing fault can take down an API gateway that makes no DB calls itself — draw the causal chain.
3. Define a gray failure and give two examples where standard Kubernetes health checks miss it.
4. Draw the retry storm feedback loop in five steps and name the three mechanisms that break it.
5. Fill in the "does replica count help?" column from memory for crash, timing (shared dependency), Byzantine, and cascading failure.
6. Explain why a `topologySpreadConstraints` misconfiguration can make 3 replicas equivalent to 1 from an availability perspective.
7. What does "Byzantine fault" mean in practice for a Kubernetes workload, and why does replica count alone not mitigate it?

➡ Next up: **Pod & Process Chaos** — now that you know the fault taxonomy, you'll inject crash faults and OOM events and watch Kubernetes' reconciliation loop respond in real time.
