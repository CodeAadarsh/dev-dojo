# Services, kube-proxy & DNS

> **Module 02 · Course 07** — A ClusterIP is a virtual IP that exists in no interface, on no NIC. kube-proxy makes it real by writing iptables DNAT chains on every node that transparently rewrite the destination of every packet headed for the VIP. CoreDNS makes those VIPs discoverable by name. Understanding both layers — plus the EndpointSlice machinery that bridges them — is what separates engineers who "add a Service" from engineers who diagnose why traffic silently drops after a rollout.

---

## Service types

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│  ClusterIP    reachable only inside the cluster; VIP → pod IPs via kube-proxy  │
│  NodePort     ClusterIP + a port on every node's real NIC (30000–32767)        │
│  LoadBalancer NodePort + cloud/metallb-provisioned external LB in front        │
│  Headless     no VIP (clusterIP: None); DNS returns pod IPs directly           │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### ClusterIP

The default. The API server allocates a virtual IP from `--service-cluster-ip-range` (default `10.96.0.0/12`). No interface holds this IP — kube-proxy intercepts traffic via iptables/IPVS and DNAT-rewrites it to one of the ready pod IPs.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: dojo-svc-demo
spec:
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 8080
```

```bash
# the VIP — notice it's from a /12 block, not your pod CIDR
kubectl -n dojo-svc-demo get svc web -o jsonpath='{.spec.clusterIP}{"\n"}'
# -> 10.96.45.123

# there is no interface holding this IP on any node:
docker exec dojo-worker ip addr | grep 10.96    # empty
```

### NodePort

Extends ClusterIP with a port on every node's real NIC. The kube-proxy NodePort rule intercepts that port on `0.0.0.0` and DNAT-redirects to the same pod pool, regardless of whether the pod is on that node.

```bash
kubectl -n dojo-svc-demo get svc web -o jsonpath='{.spec.ports[0].nodePort}{"\n"}'
NODE_IP=$(kubectl get node dojo-worker -o jsonpath='{.status.addresses[0].address}')
curl "http://${NODE_IP}:30080/"
```

**`externalTrafficPolicy`** controls what happens for that cross-node hop:

| Policy | Behavior | Trade-off |
|---|---|---|
| `Cluster` (default) | Node without local pod relays traffic to another node | Loses original client IP; extra hop; even load distribution |
| `Local` | Node drops traffic if no local pod | Preserves client IP; no extra hop; uneven load if pods are imbalanced |

Use `Local` when client IP matters (firewall rules, geo-routing, auditing) and you accept the load imbalance risk.

### LoadBalancer

On kind, `type: LoadBalancer` provisions nothing by default — the Service sits `<pending>` for `EXTERNAL-IP` forever. For challenges that need an external IP, use:

```bash
# metallb or cloud-provider-kind
# For this course, kubectl port-forward covers everything needed:
kubectl port-forward -n dojo-svc-demo svc/web 8080:80
curl http://localhost:8080/
```

### Headless service

`clusterIP: None` skips VIP allocation entirely. kube-proxy writes no iptables rules for it. DNS resolves to individual pod IPs instead of a VIP:

```bash
kubectl -n dojo-svc-demo run dns-check --rm -it --image=nicolaka/netshoot:v0.13 -- \
  nslookup web-headless.dojo-svc-demo.svc.cluster.local
# returns one A record per ready pod, not a VIP

# for StatefulSets, each pod gets a stable DNS name:
# web-0.web-headless.dojo-svc-demo.svc.cluster.local → 10.244.1.5
# web-1.web-headless.dojo-svc-demo.svc.cluster.local → 10.244.2.3
```

Headless is the prerequisite for StatefulSet per-pod addressing and for service-mesh-level load balancing (Istio, Linkerd) that needs to enumerate pod IPs and do L7 load balancing itself, bypassing kube-proxy entirely.

---

## kube-proxy: iptables mode

kube-proxy runs as a DaemonSet. It watches Services and EndpointSlices via the API server and, when either changes, rewrites the node's iptables rules to match. The rewrite is atomic (`iptables-restore`).

### Chain structure for a ClusterIP

```
PREROUTING / OUTPUT
  └─ KUBE-SERVICES  (match: dst in service-cluster-ip-range)
       └─ KUBE-SVC-<xxxxxxxxxxxx>  (match: dst=10.96.45.123 dport=80)
            ├─ KUBE-SEP-<hash-1>   DNAT → 10.244.1.5:8080   probability 0.3333
            ├─ KUBE-SEP-<hash-2>   DNAT → 10.244.2.3:8080   probability 0.5000
            └─ KUBE-SEP-<hash-3>   DNAT → 10.244.3.7:8080   probability 1.0000
```

The probability fractions are computed so each pod gets an equal share. The first `SEP` rule matches 1-in-3 packets; of the remaining 2/3, the second rule matches 1/2 (= 1/3 overall); the last rule catches everything else (also 1/3). This is entirely stateless — each packet is independently DNAT'd, which means connection tracking (`conntrack`) is what keeps a single TCP connection going to the same pod, not the iptables rules.

```bash
# inspect the raw rules on a kind node
docker exec dojo-worker iptables -t nat -L KUBE-SERVICES -n --line-numbers | head -30
# find the SVC chain for your service
docker exec dojo-worker iptables -t nat -L -n | grep -B1 '10.96.45.123'
# dump all SEP rules (one per endpoint)
docker exec dojo-worker iptables -t nat -L -n | grep KUBE-SEP
```

**Scalability wall.** With 1000 Services × 10 endpoints each = ~40k iptables rules evaluated linearly per packet. Large clusters see `iptables-restore` latency of seconds and measurable packet-processing overhead. This is why IPVS mode exists.

### IPVS mode

IPVS (Linux Virtual Server) uses a kernel hash table: O(1) lookup regardless of service count. kube-proxy in IPVS mode creates a virtual server per ClusterIP:port and registers pod IPs as real servers:

```bash
# check if IPVS mode is active
docker exec dojo-worker ipvsadm -Ln 2>/dev/null | head -30
# if command not found or empty → still in iptables mode

# IPVS also offers real scheduling algorithms (not just random):
# rr=round-robin  lc=least-connections  sh=source-hash (session affinity)
```

Switching to IPVS requires `--proxy-mode=ipvs` on kube-proxy and the `ip_vs*` kernel modules loaded on every node. For >500 Services or >5k connections/second, the switch is worth the operational change.

---

## EndpointSlices

Before EndpointSlices (pre-1.21), a single `Endpoints` object held all pod IPs for a service. One pod restarting rewrote the entire object, triggering a full kube-proxy resync on every node. With 10k pods behind a service, that thundering herd could saturate the API server.

EndpointSlices shard the pod list into chunks of ≤100 entries. Updating one pod touches one slice:

```bash
kubectl -n dojo-svc-demo get endpointslices -l kubernetes.io/service-name=web
kubectl -n dojo-svc-demo get endpointslice <name> -o yaml
```

The critical field is `.endpoints[].conditions.ready`. kube-proxy **only** adds a pod to the DNAT pool when this is `true`. This is driven by the pod's `readinessProbe` status — not the pod phase. A pod in `Running` phase with a failing readiness probe will have `conditions.ready: false` in the EndpointSlice and will receive **zero traffic**. A pod with no readiness probe at all is considered ready the moment it's `Running`, which means traffic arrives before the app has finished initializing.

```bash
# check which pods are actually in the traffic pool
kubectl -n dojo-svc-demo get endpointslice <name> \
  -o jsonpath='{range .endpoints[*]}{.addresses[0]} ready={.conditions.ready}{"\n"}{end}'
# 10.244.1.5 ready=true
# 10.244.2.3 ready=false   ← this pod is Running but NOT receiving traffic
```

This is the single most common cause of "my new pod isn't getting traffic" after a rollout: the readiness probe hasn't passed yet, so the EndpointSlice still shows `ready=false`.

---

## CoreDNS resolution & ndots

CoreDNS is the cluster DNS server (runs as a Deployment in `kube-system`, VIP at `10.96.0.10` by default). The kubelet injects `/etc/resolv.conf` into every pod:

```
nameserver 10.96.0.10
search dojo-svc-demo.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

**ndots:5** means: if a query has fewer than 5 dots, treat it as relative and try appending each `search` domain before treating it as absolute. For in-cluster names this is a win — `web` resolves in one lookup:

```
web → web.dojo-svc-demo.svc.cluster.local   (first search domain, hits)
```

For external hostnames it's expensive. `api.stripe.com` has 2 dots (fewer than 5), so CoreDNS tries all three search domains before the absolute lookup:

```
api.stripe.com.dojo-svc-demo.svc.cluster.local   NXDOMAIN
api.stripe.com.svc.cluster.local                 NXDOMAIN
api.stripe.com.cluster.local                     NXDOMAIN
api.stripe.com.                                  → resolves  (4th query)
```

That's 4 DNS queries per external hostname. A microservice calling 5 external APIs at 50 req/s is generating 1000 DNS queries/second against CoreDNS for names that will never be in the cluster. The mitigation:

```yaml
# in the pod spec
spec:
  dnsConfig:
    options:
      - name: ndots
        value: "1"   # only append search domains if there are 0 dots in the name
```

Or use fully-qualified domain names with a trailing dot: `api.stripe.com.` (the trailing dot forces absolute lookup, bypassing ndots entirely).

**SRV records for StatefulSets:**

```bash
kubectl -n dojo-svc-demo run dns-debug --rm -it --image=nicolaka/netshoot:v0.13 -- bash

# inside the container:
# A record for headless pod
nslookup web-0.web-headless.dojo-svc-demo.svc.cluster.local

# SRV record
nslookup -type=SRV _http._tcp.web-headless.dojo-svc-demo.svc.cluster.local

# check search domain expansion
cat /etc/resolv.conf
# verify ndots patch
dig +ndots=1 api.stripe.com @10.96.0.10 | grep -A5 ';; QUESTION'
```

**CoreDNS Corefile** is a ConfigMap — you can add plugins, rate limits, or caching without rebuilding:

```bash
kubectl -n kube-system get cm coredns -o yaml | grep -A30 'Corefile'
# the 'forward . /etc/resolv.conf' line is where external DNS queries go
# add caching with: cache 30
```

---

## Debugging Services & DNS

The sequence: check endpoints → check kube-proxy rules → check DNS → check conntrack.

| Symptom | Likely cause | Fix |
|---|---|---|
| `connection refused` to ClusterIP | No Ready endpoints; DNAT rule points nowhere (kube-proxy removes rules for empty services) | `kubectl get endpointslices`; fix readinessProbe or selector mismatch |
| Service has endpoints but traffic dropped | kube-proxy rules stale or kube-proxy pod crashed | Inspect iptables KUBE-SVC chain; rollout restart kube-proxy DaemonSet |
| DNS `SERVFAIL` or no answer for in-cluster name | CoreDNS pod down or its own network broken | `kubectl -n kube-system get pods -l k8s-app=kube-dns`; check CoreDNS logs |
| DNS resolves but takes 200–400 ms | ndots search domain waterfall | Count dots in the hostname; patch `dnsConfig.options.ndots` |
| Intermittent `connection reset` under high load | conntrack table full; kernel silently drops new connections | Check `nf_conntrack` table usage; raise `nf_conntrack_max`; or switch to IPVS |
| New pod `Running` but not receiving traffic | EndpointSlice `conditions.ready=false` | Check endpointslice; fix or add readinessProbe |
| `curl svc` works, `curl svc.other-ns` fails | Cross-namespace DNS name needs FQDN | Use `<svc>.<ns>.svc.cluster.local` or lower ndots |
| Sticky sessions broken after pod restart | Conntrack entry for old pod IP not yet expired | `conntrack -D --dst <old-ip>` on the node; or wait for conntrack timeout |

### The exact commands

**No endpoints:**

```bash
# does the selector match any running pod?
kubectl -n dojo-svc-demo get svc web -o jsonpath='{.spec.selector}' && echo
kubectl -n dojo-svc-demo get pods --show-labels
# the label key=value in selector must appear in LABELS column above

# are the endpoints marked ready?
kubectl -n dojo-svc-demo get endpointslices -l kubernetes.io/service-name=web
kubectl -n dojo-svc-demo get endpointslice <name> \
  -o jsonpath='{range .endpoints[*]}{.addresses[0]} ready={.conditions.ready}{"\n"}{end}'
```

**Stale kube-proxy rules:**

```bash
# verify the KUBE-SVC chain exists and has SEP entries
docker exec dojo-worker iptables -t nat -L -n | grep -A10 'KUBE-SVC'

# if missing, kube-proxy may be down
kubectl -n kube-system get pods -l k8s-app=kube-proxy

# force a resync
kubectl -n kube-system rollout restart daemonset/kube-proxy
kubectl -n kube-system rollout status daemonset/kube-proxy
```

**DNS timeout:**

```bash
# run a debug pod in the same namespace as the broken pod
kubectl -n dojo-svc-demo run dns-debug --rm -it --image=nicolaka/netshoot:v0.13 -- bash

# inside:
cat /etc/resolv.conf
nslookup web 10.96.0.10               # hit CoreDNS directly, bypass search domains
nslookup web.dojo-svc-demo.svc.cluster.local 10.96.0.10
dig @10.96.0.10 web.dojo-svc-demo.svc.cluster.local +stats   # shows query time

# CoreDNS logs (enable errors plugin in Corefile to get more detail)
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50
```

**conntrack table:**

```bash
# is the table near its ceiling?
docker exec dojo-worker sh -c \
  'echo "$(cat /proc/net/nf_conntrack | wc -l) / $(cat /proc/sys/net/netfilter/nf_conntrack_max)"'
# anything above 80% → you'll see drops soon

# find and flush stale entries for a specific pod IP
docker exec dojo-worker sh -c 'conntrack -L --dst 10.244.1.7 2>/dev/null | head -5'
# flush: docker exec dojo-worker conntrack -D --dst 10.244.1.7

# raise the ceiling (apply via DaemonSet initContainer in production)
docker exec dojo-worker sysctl -w net.netfilter.nf_conntrack_max=262144
```

> **War story.** At SAP we ran a Loki write-path at 40k log streams/minute through a ClusterIP-fronted service. Every hour, on the dot, we'd see 15 seconds of 503s on the ingest endpoint. Pod health was clean, CoreDNS was clean, app metrics showed no GC pauses. Culprit: the nf_conntrack table — sized for a 2019-era cluster at 65536 entries — filled up at ~58 minutes, and the kernel silently dropped new connections for the ~15 seconds it took for old ESTABLISHED entries to age out (default timeout: 432000 seconds, five days). The cluster control plane logged nothing. Fix: set `net.netfilter.nf_conntrack_max=1048576` via a DaemonSet initContainer on every node, and switch the ingest path to IPVS mode (IPVS uses its own connection table, separate from nf_conntrack). 503s dropped to zero. The lesson: conntrack is invisible kernel state with a hard ceiling that Kubernetes will never warn you about until the ceiling is hit.

---

## Checkpoint

You're ready for the service mesh challenges when you can, without looking anything up:

1. Trace a TCP SYN from a pod to a ClusterIP step by step through the iptables DNAT chain and explain how conntrack keeps the reply going to the right pod.
2. Explain the difference between `externalTrafficPolicy: Cluster` and `Local` — what changes at the network level and what the trade-off is.
3. Look at a KUBE-SVC chain with 4 endpoints and explain how the probability values produce equal distribution without maintaining per-connection state.
4. Show why `ndots:5` causes 4 DNS queries for `api.stripe.com` and write the one-liner `dnsConfig` patch to reduce it to 1.
5. Use `get endpointslice` with `-o jsonpath` to determine whether kube-proxy is routing traffic to a newly started pod — without `describe pod`.
6. Diagnose a conntrack saturation event on a kind node: what files to read, how to measure proximity to the ceiling, and the sysctl that raises it.
7. Explain why a Headless service enables per-pod DNS records and a regular ClusterIP service doesn't — in terms of what CoreDNS stores for each.

➡ Next: **Ingress & the Gateway API** — from iptables VIPs to L7 routing: path and host rules, TLS termination, the GatewayClass/Gateway/HTTPRoute hierarchy, and why `ndots` doesn't fix a missing `ReferenceGrant`.
