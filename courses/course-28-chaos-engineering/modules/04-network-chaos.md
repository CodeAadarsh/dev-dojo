# Network Chaos

> **Module 04 · Course 28** — Network failures are not binary. Between "everything works" and "everything is down" is a large, ambiguous territory of partial failures: slow packets, dropped retries, split quorums, expired DNS TTLs. Your system can *appear* healthy while silently corrupting user experience or data. This module gives you the tools to inject and diagnose these faults.

---

## Why network chaos is the high-value experiment

A pod kill is a crisp fail-stop event with well-understood Kubernetes responses. Network faults are ambiguous, probabilistic, and time-dependent — which is precisely why they cause more real incidents than pod crashes. Under network chaos:

- Clients can't distinguish "server is slow" from "server is dead" (both look like a timeout)
- Timeouts that seemed generous become tight once latency is added
- Retries that seemed safe become storms
- Consensus algorithms that seemed robust lose quorum
- DNS that seemed transparent becomes a hard single point of failure

Network chaos is also the easiest category to inject and the hardest to reason about in advance. You can model the retry math all day — the chaos experiment tells you what actually happens when theory meets production traffic.

---

## Tool: `tc` and `netem` inside kind nodes

Linux traffic control (`tc`) with the `netem` queuing discipline is the standard tool for injecting network faults at the OS level. In a kind cluster, you inject it *inside* the node container via `docker exec`:

```bash
# Add 200ms latency to all traffic on eth0 of a worker node:
docker exec dojo-worker tc qdisc add dev eth0 root netem delay 200ms

# Latency with jitter: 200ms ± 50ms (normal distribution):
docker exec dojo-worker tc qdisc add dev eth0 root netem delay 200ms 50ms distribution normal

# Packet loss: 10% of packets dropped randomly:
docker exec dojo-worker tc qdisc add dev eth0 root netem loss 10%

# Latency + loss combined:
docker exec dojo-worker tc qdisc add dev eth0 root netem delay 100ms loss 5%

# Check current qdisc (confirm it's set):
docker exec dojo-worker tc qdisc show dev eth0

# Remove all qdiscs (cleanup / abort):
docker exec dojo-worker tc qdisc del dev eth0 root
```

> **`tc` is node-global.** Every pod on `dojo-worker` is affected when you modify `eth0`. This includes kube-proxy traffic, CNI heartbeats, and any other pod on that node — not just your target workload. To target a specific pod, you need the pod's virtual ethernet interface (`veth*`). Find it with `ip link show` inside the node, then replace `eth0` with the pod's veth name. For production-grade per-pod targeting, use Chaos Mesh instead — it operates at the Pod/container level via init containers that manipulate the pod's network namespace.

---

## Latency injection

Latency is the most common real-world network fault and the hardest to diagnose because it is invisible to binary health checks. A pod behind a 500ms-latency network is technically healthy; it just doesn't respond in time.

### Timeout budget erosion

Every distributed call chain has an implicit end-to-end timeout budget. Latency injected at the network level consumes that budget across every hop:

```
Client (end-to-end timeout: 1s)
  → Service A (its own timeout to B: 800ms) — injected 200ms → 600ms remaining
      → Service B (its own timeout to C: 600ms) — injected 200ms → 400ms remaining
          → Database — injected 200ms → 200ms for actual query

Under 200ms injected latency per hop: works, barely.
Under 300ms injected latency per hop: Service A's 800ms budget is consumed
  before the DB query returns. API gateway sees Service A time out and
  fails the entire request — from a user's perspective, the DB caused a
  failure they never directly touched.
```

This is **timeout budget erosion**: one modest latency injection at the network layer surfaces as a timeout at the top of the call chain, with no obvious direct cause.

### Measuring latency effect end-to-end

```bash
# Inject latency on a worker:
docker exec dojo-worker tc qdisc add dev eth0 root netem delay 300ms

# Measure from inside the cluster using a debug pod:
kubectl run tmp --rm -it \
  --image=nicolaka/netshoot:v0.13 \
  --restart=Never \
  -n dojo-chaos-net -- bash

# Inside netshoot — measure time-to-first-byte breakdown:
curl -w "dns:%{time_namelookup}s connect:%{time_connect}s ttfb:%{time_starttransfer}s total:%{time_total}s\n" \
  -o /dev/null -s http://web-svc.dojo-chaos-net/

# Watch p99 shift under sustained load:
wrk -t2 -c20 -d30s --latency http://web-svc.dojo-chaos-net/
```

---

## Packet loss

Packet loss is harder to diagnose than latency because TCP's retransmission mechanism hides it. A 10% packet loss rate does not produce 10% request errors — TCP retransmits dropped packets, so it manifests first as *latency* (the retransmit timer adds ~200ms per dropped packet) and eventually as timeouts and connection failures.

```bash
# 10% packet loss:
docker exec dojo-worker tc qdisc add dev eth0 root netem loss 10%

# 25% loss (connections begin timing out, API server may feel sluggish):
docker exec dojo-worker tc qdisc add dev eth0 root netem loss 25%

# 50%+ loss (etcd heartbeats may be lost, triggering leader election):
docker exec dojo-worker tc qdisc add dev eth0 root netem loss 50%
```

What to observe at each level:

| Loss rate | Application effect | Kubernetes effect |
|-----------|-------------------|-------------------|
| 5% | Higher p99, occasional timeout retries | `kubectl` feels slow |
| 15% | Short timeouts start firing consistently | Prometheus scrapes may have gaps |
| 30% | TCP connections start failing; ETIMEDOUT errors | kube-proxy iptables sync slows; endpoint updates lag |
| 50%+ | Most connections fail; service effectively down | etcd may lose heartbeats; leader election fires |

The lesson: packet loss exercises your timeout and retry logic before it exercises your circuit breaker. It's the early warning of a network degradation, not the crisis itself.

---

## Network partitions and split-brain

A partition is when a subset of nodes can't reach another subset. Unlike latency and loss faults, a partition is *symmetric* and *total* — from each side's perspective, the other side has completely disappeared.

### What a partition means for consensus systems

Any system that requires quorum — etcd, ZooKeeper, Redis Sentinel, Raft-based services — must choose when partitioned (the CAP theorem):

- **Accept writes on both sides (availability):** Each side continues serving but diverges → split-brain
- **Reject writes on the minority side (consistency):** Only the majority quorum accepts writes; the minority side stops serving or serves reads with a staleness caveat

etcd is CP. With 3 etcd nodes and a partition that isolates 1 from the other 2:
- Majority side (2 nodes): still has quorum, accepts writes, Kubernetes API server works
- Minority side (1 node): no quorum, refuses writes, any API server talking to this etcd node returns errors

```bash
# Simulate a partition: block all traffic between worker1 and worker2
WORKER1_IP=$(docker inspect dojo-worker --format '{{.NetworkSettings.Networks.kind.IPAddress}}')
WORKER2_IP=$(docker inspect dojo-worker2 --format '{{.NetworkSettings.Networks.kind.IPAddress}}')

docker exec dojo-worker  iptables -A OUTPUT -d "$WORKER2_IP" -j DROP
docker exec dojo-worker  iptables -A INPUT  -s "$WORKER2_IP" -j DROP
docker exec dojo-worker2 iptables -A OUTPUT -d "$WORKER1_IP" -j DROP
docker exec dojo-worker2 iptables -A INPUT  -s "$WORKER1_IP" -j DROP

# Observe: pods on worker1 can't reach pods on worker2 by pod IP
# kube-proxy's iptables rules still contain the old pod IPs for Services
# → some Service requests succeed (routed to worker1 pods), some fail (routed to worker2 pods)

# Cleanup:
docker exec dojo-worker  iptables -D OUTPUT -d "$WORKER2_IP" -j DROP
docker exec dojo-worker  iptables -D INPUT  -s "$WORKER2_IP" -j DROP
docker exec dojo-worker2 iptables -D OUTPUT -d "$WORKER1_IP" -j DROP
docker exec dojo-worker2 iptables -D INPUT  -s "$WORKER1_IP" -j DROP
```

### Kubernetes graceful degradation under partition

The Kubernetes control plane (API server + etcd) runs on the control-plane node. If worker nodes are partitioned from the control plane:
- Existing pods on the workers **keep running** — kubelet continues managing them locally
- No new scheduling happens (scheduler can't write to etcd)
- New Secrets and ConfigMaps don't propagate to workers
- HPA can't scale; rolling updates stall

This is Kubernetes' graceful degradation: workers continue serving existing workloads in island mode. Understanding this boundary tells you exactly what chaos experiments involving partitions are and are not testing.

---

## DNS failure

DNS is a hidden dependency that most resilience designs ignore — because it's transparent when working and catastrophic when broken.

In Kubernetes, every pod's DNS is served by CoreDNS (running in `kube-system`). DNS failures manifest as:
- `dial tcp: lookup <service>: no such host` — CoreDNS is down or unreachable from the pod
- Slow DNS responses — CoreDNS is overloaded or its upstream resolver is timing out
- Stale records — the pod IP in DNS doesn't match the actual pod (after pod replacement, before TTL expiry)

### Injecting DNS failure

```bash
# Option 1: scale CoreDNS to 0 — everything that lacks a cached DNS entry fails
kubectl scale deploy coredns -n kube-system --replicas=0

# Watch what breaks immediately:
kubectl logs -n dojo-chaos-net deploy/web --tail=20 -f

# Restore:
kubectl scale deploy coredns -n kube-system --replicas=2

# Option 2: block UDP port 53 from a specific node (more surgical blast radius):
docker exec dojo-worker iptables -A OUTPUT -p udp --dport 53 -j DROP

# Every pod on dojo-worker can no longer resolve DNS — even cached connections that are
# closed and reopened will fail. Health checks that use hostnames (not IPs) will also fail.

# Restore:
docker exec dojo-worker iptables -D OUTPUT -p udp --dport 53 -j DROP
```

### DNS TTL and stale records

Kubernetes Service DNS has a TTL of 5 seconds (CoreDNS default). Pod DNS (headless services) has the same TTL. After a pod restart:
1. CoreDNS updates its record with the new pod IP
2. Old IP is invalidated in CoreDNS
3. Clients with a cached DNS entry continue hitting the old IP for up to 5 seconds

5 seconds of stale DNS is usually acceptable. The problem arises when:
- A language runtime caches DNS indefinitely (JVM's `networkaddress.cache.ttl` defaulted to `-1` for security reasons — meaning forever)
- A service mesh sidecar has an independently configured, longer DNS cache
- The application pools TCP connections and never re-resolves, so DNS staleness accumulates indefinitely

```bash
# Check CoreDNS cache TTL config:
kubectl get configmap coredns -n kube-system -o yaml | grep -A5 'cache'

# Check CoreDNS pod health and resource usage:
kubectl top pod -n kube-system -l k8s-app=kube-dns

# From inside a pod, confirm it's pointing at CoreDNS:
kubectl exec -n dojo-chaos-net deploy/web -- cat /etc/resolv.conf
# -> nameserver should be the kube-dns ClusterIP (kubectl get svc -n kube-system kube-dns)

# Check the CoreDNS ClusterIP:
kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}{"\n"}'
```

---

## Bandwidth limits

Bandwidth limits model cross-region WAN links, throttled cloud networking, or an egress-limited container network interface.

```bash
# Limit a worker node to 1 Mbit/s (token bucket filter):
docker exec dojo-worker tc qdisc add dev eth0 root \
  tbf rate 1mbit burst 32kbit latency 400ms

# 100ms RTT + 10 Mbit/s = approximate cross-region WAN simulation:
docker exec dojo-worker tc qdisc add dev eth0 root \
  netem delay 100ms 10ms && \
docker exec dojo-worker tc qdisc add dev eth0 parent 1:1 \
  tbf rate 10mbit burst 32kbit latency 400ms

# Cleanup:
docker exec dojo-worker tc qdisc del dev eth0 root
```

Workloads that degrade first under a 1 Mbit/s limit:
- Large image pulls (Pod startup time increases from seconds to minutes)
- gRPC streaming connections (backpressure causes stream stalls)
- Prometheus `remote_write` (samples back up; scrape gaps appear)
- File upload / download APIs (obviously)

Bandwidth limits are most useful for testing whether your application handles backpressure correctly — does it queue, shed load, or crash?

---

## Debugging network chaos

### Timeout cascades

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| API gateway times out on a request that doesn't touch the slow service | Timeout budget erosion across the call chain; each hop consumes the injected latency | Instrument per-hop timeout independently; use per-RPC deadlines (gRPC context) or `X-Request-Timeout` headers; verify client timeout > injected latency + server processing time |
| A single 300ms latency injection causes 5× the expected error rate | Retries without backoff: each timed-out request retries N times, each retry also hits the slow path | Calculate `max-retries × client-timeout ≤ SLO budget`; add circuit breaker with a fast-fail threshold when the error rate exceeds a bound |
| Health checks pass but users see errors | Health check endpoint bypasses the slow code path; it's checking a fast `GET /healthz` while real requests call the DB | Health checks must exercise the actual dependency path; a `/healthz` that returns 200 without touching the DB is not a steady-state signal |
| After removing latency injection, errors persist for 2–3 minutes | TCP connections stuck in TIME_WAIT; connection pool is not recovering and reconnecting | Set TCP keepalive; configure max connection age in the pool; set `keep-alive: false` on short-lived client connections |

### Partition-induced split-brain

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Redis writes succeed on two separate pods but data diverges | Redis Sentinel failed to prevent dual-master promotion during the partition window | Set `min-replicas-to-write: 1` to prevent the minority-side master from accepting writes; validate Sentinel failover behavior in a chaos experiment *before* running in prod |
| `kubectl` commands succeed but applied objects never appear | Client is talking to the API server that happens to share the etcd minority node; that etcd node has stopped accepting writes | Check etcd cluster health: `kubectl exec -n kube-system etcd-dojo-control-plane -- etcdctl endpoint health --cluster`; ensure all API server instances point to healthy etcd endpoints |
| Pods on worker1 reach worker2 pod IPs directly but fail via Service names | kube-proxy on worker1 has stale iptables rules for Services whose endpoints are on worker2 | After a partition heals, force kube-proxy to sync: check `kubectl get endpoints -n <ns>` for current pod IPs vs the rules in `iptables -t nat -L -n` |

### DNS as a hidden dependency

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Service fails intermittently with "no such host" despite the destination being healthy | A pod restarted; its DNS record updated; a client cached the old IP and never re-resolved | Close and re-open connections when receiving a connection error, not just on timeout; implement connection-level health checks |
| Failures disappear at high load and reappear at low load | Under low load, connections are closed and reopened, triggering DNS re-resolution that hits the stale cache window. Under high load, connections are reused, bypassing DNS. | Consistent connection pooling; set `maxIdleTime` on the pool to force periodic re-resolution |
| `kubectl` is slow, but not returning errors | CoreDNS is overloaded; API server FQDN resolution is queuing | `kubectl top pod -n kube-system -l k8s-app=kube-dns`; add a second CoreDNS replica; tune the `autopath` plugin to reduce fanout from FQDN expansion |
| A Java or Go service returns DNS errors hours after a pod restart | JVM's `networkaddress.cache.ttl = -1` (cache forever); Go's default resolver respects TTL but caches results for `5 × TTL` | Set JVM flag `-Dnetworkaddress.cache.ttl=10`; for Go, verify `GODEBUG=netdns=go` is set and the resolver is not being overridden |

> **War story.** During a Kubernetes upgrade at SAP, we rolled worker nodes one at a time: cordon, drain, upgrade, uncordon. On node 3 drain, a Spring Boot service started returning 503s on roughly 15% of requests. Everything else looked clean: pods were Ready, Deployment was healthy, Prometheus showed no spikes. After 20 minutes we found the cause: a CoreDNS ConfigMap change earlier that day had restarted the CoreDNS pods, giving them new pod IPs. Every Java service that had been running since before the ConfigMap change had the old CoreDNS IP cached — the JVM default is `networkaddress.cache.ttl = -1`, meaning forever. The 15% failure rate corresponded exactly to the fraction of DNS lookups that went to the old, dead CoreDNS IP. Connections to existing services succeeded (they didn't need DNS); new connections requiring a fresh lookup failed. Fix: add `-Dnetworkaddress.cache.ttl=10 -Dnetworkaddress.cache.negative.ttl=5` to the JVM args for every Java service in the cluster. The lesson: DNS cache TTL is a language-runtime setting, not a Kubernetes setting. Kubernetes cannot fix a JVM that caches DNS forever. Audit your runtimes before any infrastructure change that moves pod IPs.

---

## Checkpoint

You're ready for the chaos challenges when you can, without looking anything up:

1. Write the `tc netem` command to inject 200ms latency with 50ms jitter (normal distribution) on a kind worker's eth0, and the cleanup command.
2. Explain timeout budget erosion across a 3-hop call chain with 200ms injected latency per hop and a 500ms end-to-end timeout.
3. Describe what 10% packet loss looks like at the TCP level versus the application level — why doesn't 10% loss cause 10% errors?
4. Explain what happens to the Kubernetes control plane's behavior when worker nodes are partitioned from the control-plane node — what keeps working, what stops?
5. Give three concrete ways DNS can cause a gray failure in Kubernetes, and write the command to check CoreDNS pod health and resource usage.
6. Write the `tc tbf` command for bandwidth limiting to 1 Mbit/s, and name two Kubernetes workloads that degrade first under that limit.
7. Describe the "DNS cached forever" failure mode, identify which runtime is most often the cause, and state the JVM flag that fixes it.
8. State the `iptables` rule that blocks UDP port 53 from a kind worker node, and explain which pods are affected (scope your answer).

➡ Next up: the **chaos challenges** — inject these faults against a live kind cluster, observe the steady state, and prove your resilience properties hold.
