# Services, DNS & Ingress

> **Module 04 · Course 01** — A pod IP is a lie you can't build on: it changes on every reschedule. Everything about reaching a workload — Services, kube-proxy, Endpoints, CoreDNS, Ingress — exists to put a *stable* name and address in front of a fleet of mortal pods. This module is about how that machinery actually works, so that when traffic doesn't flow you can reason about *which layer* broke instead of guessing.

You already wire up Services at work. The goal here is the layer below the YAML: what kube-proxy writes into the kernel, how readiness gates the Endpoints list, what CoreDNS resolves and why, and where Ingress ends and the controller begins.

---

## The four Service types, and what each is really for

A Service is a stable virtual IP (the **ClusterIP**) plus a label selector. The selector is continuously evaluated to produce a list of backend pod IPs. The type only changes *how far out* that ClusterIP is exposed.

| Type | What it adds | Reach | Use it for |
|------|--------------|-------|-----------|
| `ClusterIP` (default) | A cluster-internal virtual IP | In-cluster only | East-west traffic between services |
| `NodePort` | Opens the same port on *every* node (30000–32767) | `nodeIP:nodePort` | Bare-metal, dev, or a layer under an external LB |
| `LoadBalancer` | Asks the cloud provider for an external LB → NodePort → ClusterIP | Public IP | The front door in a cloud (EKS/GKE/AKS) |
| Headless (`clusterIP: None`) | *No* virtual IP; DNS returns pod IPs directly | In-cluster, per-pod | StatefulSets, when the client needs each pod |

The mental model that matters: **`LoadBalancer` is a superset of `NodePort` is a superset of `ClusterIP`.** A `LoadBalancer` Service still has a ClusterIP and still allocates a NodePort — the cloud LB just forwards to that NodePort. If east-west stops working, the cloud LB is irrelevant; debug the ClusterIP.

```
┌──────────── LoadBalancer ────────────┐
│  cloud LB (external IP :80)           │
│        │                              │
│  ┌───── NodePort ─────┐               │
│  │  every node :31234 │               │
│  │     │              │               │
│  │  ┌── ClusterIP ──┐ │               │
│  │  │ 10.96.x.x:80  │ │  ← selector → pod IPs
│  │  └───────────────┘ │               │
│  └────────────────────┘               │
└───────────────────────────────────────┘
```

> **Headless is not a weaker ClusterIP — it's a different contract.** With `clusterIP: None`, there is no virtual IP and no load balancing. A DNS lookup of the Service returns *one A record per ready pod*. That's exactly what a StatefulSet client (a Kafka broker, a Postgres replica, a peer-discovering cluster) needs: it wants to talk to `pod-0` specifically, not "some backend."

---

## How kube-proxy implements a Service: iptables vs IPVS

Here is the fact that surprises people: **nothing listens on a ClusterIP.** It is not a process, not an interface. It's a rule in the kernel's packet path, programmed by **kube-proxy** on every node. When a pod sends a packet to `10.96.0.10:80`, the kernel rewrites (DNATs) the destination to a real pod IP before the packet ever leaves the node.

kube-proxy has two production dataplanes:

| | **iptables mode** (default) | **IPVS mode** |
|---|---|---|
| Backend selection | A chain of probabilistic rules | A hash table in the kernel's L4 load balancer |
| Rule lookup | O(n) — linear scan of rules | O(1) — hash lookup |
| Scale ceiling | Degrades past ~1–5k Services | Handles tens of thousands |
| LB algorithms | Random only | rr, lc, dh, sh, and more |
| Rule reload cost | Rewrites large rule sets | Incremental |

In iptables mode each Service becomes a `KUBE-SERVICES` rule that jumps to a per-service chain, which picks a backend with `statistic --probability` and DNATs to it:

```
# conceptually, for a 3-endpoint Service:
-A KUBE-SVC-XXX -m statistic --mode random --probability 0.333  -j KUBE-SEP-A
-A KUBE-SVC-XXX -m statistic --mode random --probability 0.500  -j KUBE-SEP-B
-A KUBE-SVC-XXX                                                   -j KUBE-SEP-C
```

That `0.333 → 0.5 → fallthrough` cascade is how iptables fakes an even 1/3 split across three endpoints. Every connection re-rolls the dice, so iptables load balancing is per-connection random, not round-robin.

**Edge case — existing connections never rebalance.** The DNAT decision is made once, at connection setup, and recorded in the kernel's conntrack table. An already-established TCP connection stays pinned to its original backend pod for its entire life. So scaling a Service *up* does nothing for clients holding long-lived connections (gRPC channels, DB pools, HTTP keep-alive) — they keep hammering the old pods until they reconnect. "I added replicas but the load didn't spread" is almost always this, not a scheduler bug; the fix is client-side connection cycling (max-connection-age), not more pods.

> **Why you care at 100GB/day:** the control-plane cost of iptables mode is *rule churn*. Every endpoint change rewrites rules, and at thousands of Services the sync time grows until Service updates lag reality. On a large LGTM/observability footprint this shows up as slow propagation after a deploy. IPVS (or Cilium's eBPF dataplane, which replaces kube-proxy entirely) is the usual answer. Check your mode with `kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep mode`.

---

## Endpoints, EndpointSlices, and how readiness gates traffic

The selector is only half the story. The other half is **which matching pods are actually eligible** — and that is controlled by **readiness**, not by the pod merely existing.

The flow:

```
Deployment pods (label app=web)
        │  endpoints controller watches
        ▼
  readiness probe passing?
     ┌──────┴──────┐
    yes            no
     │              │
 in Endpoints   excluded
     │              │
 kube-proxy     no traffic
 programs rule  routed here
```

- **Endpoints** (the original `v1` object) is a single object listing all backend addresses for a Service. It doesn't scale: one 5,000-pod Service means one enormous object rewritten on every change.
- **EndpointSlices** (`discovery.k8s.io/v1`, default since 1.21) shard that list into chunks of ~100 endpoints, so a single pod change rewrites one small slice instead of one giant object. This is what makes large Services tractable.

```bash
kubectl -n dojo-net get endpointslices -l kubernetes.io/service-name=web
kubectl -n dojo-net get endpointslices -o jsonpath='{.items[*].endpoints[*].conditions.ready}'
```

The load-bearing detail: a pod only lands in the **ready** address set of a slice when its **readinessProbe passes**. This is the mechanism behind the zero-downtime rollout you built in *Make It Survive* — `maxUnavailable: 0` keeps old pods alive, and the readiness gate keeps new pods *out of Endpoints* until they can serve. Remove the probe and you route traffic into a pod that's still warming up.

> **The `terminating` trap.** When a pod is deleted it's removed from Endpoints *before* it finishes shutting down. If your container exits instantly on SIGTERM, in-flight requests get connection-reset. The fix is a `preStop` sleep (e.g. `sleep 5`) plus a `terminationGracePeriodSeconds` long enough to drain — it keeps the pod serving existing connections during the window where kube-proxy is still removing the rule across all nodes.

> **The named-port trap.** A Service `targetPort` may be a *name* (`targetPort: http`) that must match a `ports.name` in the pod spec — not the container port number. Rename or drop that port name on the pod and the Service silently resolves to nothing: the selector still matches, pods are Ready, endpoints populate — but the *port* is wrong, so every connection is refused. This is the maddening "Ready, endpoints present, still connection-refused" bug. Prefer a numeric `targetPort`, or grep both specs when it appears.

---

## CoreDNS and service DNS names

Pods don't hardcode ClusterIPs — they use DNS names, resolved by **CoreDNS** (running as a Deployment in `kube-system`). Every pod's `/etc/resolv.conf` points at the CoreDNS Service ClusterIP.

The canonical form of a Service DNS name:

```
<service>.<namespace>.svc.cluster.local
└──┬────┘ └───┬────┘ └┬┘ └────┬─────┘
 service   namespace  type  cluster domain
```

The `search` domains in `resolv.conf` let you abbreviate:

| From a pod in `dojo-net` | Resolves to |
|--------------------------|-------------|
| `web` | `web.dojo-net.svc.cluster.local` (same namespace) |
| `web.dojo-other` | the `web` Service in `dojo-other` |
| `web.dojo-other.svc` | same, fully `svc`-qualified |
| `web.dojo-other.svc.cluster.local` | fully qualified, no search-list expansion |

```bash
# from a throwaway debug pod:
kubectl -n dojo-net run tmp --rm -it --image=nicolaka/netshoot -- \
  sh -c 'nslookup web && nslookup web.dojo-net.svc.cluster.local'
```

Two things worth knowing cold:

- **Headless Services return multiple A records** — one per ready pod — instead of a single ClusterIP. StatefulSet pods additionally get stable per-pod names: `web-0.web.dojo-net.svc.cluster.local`.
- **`ndots:5`** is set in pod `resolv.conf` by default. Any name with fewer than 5 dots is tried against every search domain *first*. That means `api.example.com` (3 dots) generates four failing internal lookups before the external one succeeds — a classic source of DNS latency and CoreDNS load. Fully-qualify external names (trailing dot) or tune `dnsConfig.options` to cut it.

> **Security thread:** CoreDNS resolves across *all* namespaces by default — a pod in `dojo-a` can resolve and reach a Service in `dojo-b`. Namespaces are an organizational boundary, **not** a network boundary. That gap is exactly what NetworkPolicy closes (below).

> **War story.** A service's p99 latency tripled after a migration that "changed nothing but a config value": an upstream hostname went from `cache.internal.` (fully qualified, trailing dot) to bare `cache`. With `ndots:5`, every outbound request now generated five sequential DNS lookups — four guaranteed-NXDOMAIN against the search domains, then the real one — and those extra round-trips, multiplied across a 100GB/day ingest fleet, buried CoreDNS in NXDOMAIN traffic until *its* own latency climbed and it began timing out legitimate internal lookups too. The fix was a one-character diff: restore the trailing dot. `ndots:5` is the most expensive default in Kubernetes networking, and it stays invisible until a hot path crosses it.

---

## Ingress: resource vs controller

A `Service type=LoadBalancer` per app means one cloud LB (and one bill, one public IP) per service. **Ingress** collapses many HTTP services behind a single entry point with host- and path-based routing, TLS termination, and rewrites.

The split that confuses people:

- **The Ingress *resource*** is just declarative config — "host `app.example.com` path `/api` → Service `api:80`." It does nothing on its own.
- **The Ingress *controller*** (ingress-nginx, Traefik, HAProxy, cloud-native ones) is the pod that *watches* Ingress resources and reconfigures a real reverse proxy to match. **No controller installed = your Ingress resource is inert YAML.**

```
         Ingress resource (rules)
                 │  watched by
                 ▼
   ┌──── ingress-nginx controller pod ────┐
   │   reverse proxy, reloads on change    │
   └───────────────┬───────────────────────┘
      host/path →   │   → ClusterIP Service → pods
   app.example/api  │       api:80
   app.example/     │       web:80
```

A minimal Ingress with a `pathType` (always set it — `Prefix` vs `Exact` changes matching semantics):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  namespace: dojo-net
spec:
  ingressClassName: nginx
  rules:
    - host: web.dojo.localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 80
```

> **`ingressClassName` is not optional in practice.** With multiple controllers (or none), an Ingress with no class is ambiguous and may be ignored. Name the class explicitly.

### ingress-nginx on kind

The dojo cluster is configured so the control-plane node maps **host 8080 → container 80** (and 8443 → 443). Install the kind-tuned controller with the bootstrap script:

```bash
bash labs/bootstrap/install-ingress.sh
```

That applies the kind provider manifest and waits for the controller pod to be ready. Once it is, an Ingress is reachable from your Mac at `http://localhost:8080` — send the right `Host` header so the controller matches the rule:

```bash
curl -H 'Host: web.dojo.localhost' http://localhost:8080/
```

If you get a 404 from nginx, the controller is up but no rule matched (wrong host/path or missing `ingressClassName`). If the connection is refused, the controller pod isn't ready — `kubectl -n ingress-nginx get pods`.

---

## Security thread: the default-allow problem (NetworkPolicy teaser)

Here's the uncomfortable default: **an empty cluster is flat.** Any pod can open a connection to any other pod, in any namespace, on any port. Your `dojo-leaky` billing pod can reach the `payments` database in another namespace with nothing stopping it. There is no implicit firewall.

A **NetworkPolicy** changes the posture for the pods it selects: *the moment any policy selects a pod, that pod flips from default-allow to default-deny*, and only the traffic the policy explicitly permits is allowed. The canonical first policy is a namespace-wide default-deny for ingress:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: dojo-net
spec:
  podSelector: {}          # selects every pod in the namespace
  policyTypes: [Ingress]   # with no ingress rules below → deny all inbound
```

Two caveats that separate competent from expert:

- **NetworkPolicy needs a CNI that enforces it.** Calico, Cilium, and Weave do; the default kind CNI (kindnet) does **not** — so these policies parse but aren't enforced on the stock dojo cluster. On real clusters, confirm your CNI enforces before you trust a policy.
- **Policies are additive and whitelist-only.** There is no "deny" rule — you express what's *allowed*, and anything unmatched is denied once *any* policy selects the pod. Think allowlists, not an ordered firewall.

We'll weaponize the default-allow gap and then close it properly in the security modules. For now, internalize the posture: **Services and DNS make everything reachable by default; NetworkPolicy is the thing you add to make that stop being true.**

---

## Debugging Services, DNS & Ingress

Connectivity bugs are almost always a *layer* problem: the request dies at DNS, at the Service's Endpoints list, at kube-proxy's rules, or at the Ingress controller. Debug top-down and confirm each layer before moving to the next — most wasted hours come from suspecting DNS when the real problem is an empty Endpoints list two layers down.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `curl <svc>` hangs / connection refused, but the Service exists | Endpoints empty — selector doesn't match pod labels, or no pod is Ready | `get endpoints` → fix selector or readiness |
| Name doesn't resolve (`nslookup` NXDOMAIN) | Wrong FQDN / wrong namespace, or CoreDNS is down | Check CoreDNS pods; use full `<svc>.<ns>.svc.cluster.local` |
| External lookups slow / intermittent | `ndots:5` search-path fan-out, or CoreDNS overloaded | Fully-qualify external names (trailing dot) or set `dnsConfig` `ndots:1` |
| Ingress returns `404` (served by nginx) | No rule matched — wrong Host, path, or missing `ingressClassName` | Fix the rule's host/path and class; send the right `Host` header |
| Ingress returns `502`/`503` | Controller matched a rule but the backend has no healthy endpoints or wrong port | Check the backing Service's endpoints and port number |
| East-west works, NodePort doesn't | kube-proxy not programming rules on that node, or host firewall | Check kube-proxy pods + the node's iptables rules |
| Works from some pods, not others | kube-proxy sync lagging/crashed on one node, or conntrack table full | Check *per-node* kube-proxy; `conntrack -S` for drops |

### "Service has no endpoints" — the #1 Service bug

A Service with no endpoints is a silent black-hole: the ClusterIP exists, DNS resolves it, but kube-proxy has nothing to DNAT to, so the connection hangs or resets. One command proves it:

```bash
kubectl -n dojo-net get endpoints web          # or: get endpointslices
# web   <none>     ← empty = no backend. This is your answer.
```

Empty endpoints has exactly two causes, and you distinguish them in seconds:

```bash
# cause 1 — selector/label mismatch: the Service selects labels no pod carries
kubectl -n dojo-net get svc web -o jsonpath='{.spec.selector}{"\n"}'
kubectl -n dojo-net get pods --show-labels
# compare: does any pod carry EVERY key=value in the selector?

# cause 2 — pods match but none are Ready: readiness gates endpoint membership
kubectl -n dojo-net get pods -l app=web -o wide
kubectl -n dojo-net get endpointslices -l kubernetes.io/service-name=web \
  -o jsonpath='{.items[*].endpoints[*].conditions.ready}{"\n"}'
```

If the selector matches but endpoints are still empty, it's readiness (straight back to Module 03's readiness gate). If no pod carries the selector labels, it's a typo in `spec.selector` or the pod template `labels` — the two drift apart during refactors constantly, and nothing warns you.

### DNS resolution failures

```bash
# resolve from inside the cluster network, not from your Mac
kubectl -n dojo-net run tmp --rm -it --image=nicolaka/netshoot -- \
  sh -c 'cat /etc/resolv.conf; nslookup web; nslookup web.dojo-net.svc.cluster.local'

# is CoreDNS even up?
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50
kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}{"\n"}'   # must match resolv.conf nameserver
```

Triage order: (1) does `resolv.conf` point at the CoreDNS ClusterIP? (2) are the CoreDNS pods Running with clean logs — a `plugin/errors` or `SERVFAIL` storm means an upstream loop or a broken `Corefile`? (3) does the *short* name fail but the *FQDN* succeed? That's not an outage — it's the `ndots:5` search-path tax: `web` only resolved as `web.dojo-net.svc.cluster.local` *after* `web.<each-search-domain>` failed. For a chatty external name it's the costly direction: `api.stripe.com` (3 dots < 5) burns four internal NXDOMAIN lookups before the real one — fully-qualify it as `api.stripe.com.` or lower `ndots` in `dnsConfig`.

### Ingress 404 vs 502 — they blame different layers

The status code tells you *who* is unhappy and therefore which layer to inspect:

| Code | Who returned it | What it means |
|------|-----------------|---------------|
| `404` (nginx body) | the Ingress controller | No rule matched this Host+path — or the Ingress has no `ingressClassName`, so this controller ignored the resource entirely |
| `502` / `503` | the Ingress controller | A rule matched, but the backend Service has no healthy endpoints, or the `backend.service.port` is wrong |
| connection refused | nothing listening | Controller pod not Ready, or the kind host→container port mapping is wrong |

```bash
# 404: inspect the rules the controller actually loaded
kubectl -n dojo-net describe ingress web
kubectl -n dojo-net get ingress web -o jsonpath='{.spec.ingressClassName}{"\n"}'
curl -v -H 'Host: web.dojo.localhost' http://localhost:8080/   # exact Host the rule expects

# 502/503: the rule matched but the backend is empty — same endpoints check as above
kubectl -n dojo-net get endpoints web
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=50 | grep -i 'web.dojo'
```

A 502 through Ingress is almost always the *same empty-endpoints bug* as the direct-Service case, just one hop further out — which is why you confirm endpoints before suspecting the controller. A frequent 502 trap: the Ingress `backend.service.port.number` names a port the Service doesn't actually expose, so the controller faithfully proxies to a closed port.

### kube-proxy issues

When the ClusterIP resolves and endpoints *are* populated but traffic still won't flow, suspect the dataplane — kube-proxy either didn't program the rules or is lagging on one node:

```bash
kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide      # one per node; all Running?
kubectl -n kube-system logs -l k8s-app=kube-proxy --tail=50 | grep -iE 'err|fail|sync'

# inspect the actual NAT rules on a specific node (a kind node IS a container)
docker exec dojo-worker iptables-save -t nat | grep -i KUBE-SVC
docker exec dojo-worker conntrack -S 2>/dev/null | grep -i drop    # conntrack table full = silent drops
```

Two real-world failure modes: (1) a crashed kube-proxy on *one* node means Services work from every node except that one — the symptom is "it's broken for ~1/3 of pods," which maps exactly to the node whose proxy is down; (2) a full conntrack table (high connection churn — a load test, or a scrape-everything observability agent) silently drops *new* connections while existing ones keep working — `nf_conntrack: table full, dropping packet` in the node's `dmesg` is the fingerprint.

> **War story.** Half of a new deploy's traffic 502'd intermittently; the other half was perfectly fine. Endpoints looked full, CoreDNS was healthy, the Ingress rule matched. The tell was that failures correlated with *which node* served the request. One worker's kube-proxy pod had OOMed hours earlier and was quietly `CrashLoopBackOff`-ing — so its iptables NAT rules were frozen at a stale snapshot pointing at pod IPs that had since been rescheduled away. From that node the Service DNAT'd to dead IPs; from the others it worked. `kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide` surfaced the lone `CrashLoopBackOff` in one line. We'd burned 40 minutes on DNS and Ingress precisely because the failure was *partial*. The lesson: when a Service works from some pods and not others, go straight to per-node kube-proxy — the Service abstraction is only as healthy as the proxy on the node you happen to land on.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Explain why a ClusterIP has no process listening on it, and what kube-proxy actually programs.
2. State when you'd switch kube-proxy from iptables to IPVS, and the symptom that drives it.
3. Describe how readiness gates a pod's membership in EndpointSlices, and tie it back to zero-downtime rollouts.
4. Resolve `web.dojo-net.svc.cluster.local` by hand and explain what `ndots:5` does to external lookups.
5. Distinguish the Ingress resource from the Ingress controller, and say what breaks if the controller is missing.
6. Explain the default-allow problem and what flips when a NetworkPolicy first selects a pod.
7. Given a Service that hangs with no traffic, name the single command that tells you whether the problem is the selector or readiness.
8. Map Ingress `404` vs `502` to the layer each blames, and explain why a partial ("some pods only") Service failure points straight at per-node kube-proxy.

➡ Next up: **Config & Secrets Done Right** — ConfigMaps, the file-vs-env safety argument, immutability, and why a Kubernetes Secret is only base64 until you turn on encryption at rest.
