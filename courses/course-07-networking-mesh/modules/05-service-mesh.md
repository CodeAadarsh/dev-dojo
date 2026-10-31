# Service Mesh: Istio & Linkerd

> **Module 05 · Course 07** — NetworkPolicy lets you say "pod A may talk to pod B on port 8080." A service mesh lets you say "only requests from pods holding a valid SPIFFE certificate issued by my CA, carrying a JWT from my IdP, may reach that endpoint — with 3 retries on 5xx, a 5-second timeout, and a full latency histogram on every call." Different level of granularity entirely. This module covers why you'd reach for a mesh, how the sidecar and ambient models work, what mTLS actually does between proxies, and the failure modes that will ruin your day.

You will encounter Istio in a real cluster before long — it is the de facto default in mid-to-large organizations. Even if you don't operate it directly, understanding how Envoy intercepts traffic is the difference between "the service is down" and "the sidecar rejected the connection because mTLS was misconfigured."

---

## The problem a mesh solves

A cluster running 10+ services accumulates cross-cutting concerns that are painful to handle per-app:

- **Encryption in transit.** You've encrypted etcd, locked down Secrets. But pod-to-pod traffic on the overlay network is plaintext by default. A compromised pod can observe traffic destined for other pods on the same node.
- **Service identity and authorization.** NetworkPolicy is L3/L4: this IP on this port. A mesh adds L7 identity: this service account, carrying this certificate, may call this endpoint.
- **Observability.** Per-route latency histograms, error rates, distributed traces — you can instrument every app individually, or do it once at the proxy layer and get it everywhere.
- **Traffic control.** Canary weights, retries, timeouts, circuit breakers, fault injection — each one is a CVS worth of client library or a two-line DestinationRule.

A mesh implements these concerns in a proxy injected next to each pod. The proxy intercepts all TCP via iptables rules rewritten inside the pod's network namespace. Your application code sends plaintext to `localhost`; the proxy handles encryption, retries, and telemetry transparently.

---

## Sidecar model vs ambient model

### Sidecar (original Istio, all Linkerd versions)

At pod creation, a mutating admission webhook injects a proxy container alongside the app container. An init container (`istio-init` or `linkerd-init`) rewrites iptables inside the pod's network namespace to redirect all inbound and outbound TCP through the proxy.

```
┌──────────────────────────── pod: api ────────────────────────────────┐
│                                                                       │
│  ┌─ container: app ──┐    ┌─ container: istio-proxy (envoy) ────┐    │
│  │  binds :8080       │    │  :15006 inbound intercept            │    │
│  │  (your code)       │◄───┤  :15001 outbound intercept           │    │
│  └────────────────────┘    │  handles mTLS, retries, telemetry    │    │
│                             └──────────────────────────────────────┘   │
│        iptables rules (set by istio-init) redirect all TCP to proxy   │
└───────────────────────────────────────────────────────────────────────┘
```

Consequences worth internalizing:

- **Every pod has 2+ containers.** `kubectl get pod <name> -o jsonpath='{.spec.containers[*].name}'` shows `app istio-proxy` (or `main linkerd-proxy`).
- **Resource tax per pod.** Envoy (Istio's proxy) is not lightweight: budget 10–100m CPU and 64–256Mi RAM per pod under load. Linkerd's micro-proxy is leaner. On an 8 GB Mac Mini with a kind cluster, this adds up fast.
- **Init container failure = pod never starts.** If `istio-init` can't write iptables rules, the pod hangs at `Init:Error`. Check node-level security context, `NET_ADMIN` capability, and seccomp policy.

### Ambient model (Istio 1.x+, stable since 1.22)

Ambient removes per-pod injection. Two node-level components replace it:

- **ztunnel** — a DaemonSet on each node that handles L4 mTLS and telemetry for all pods on that node, with no sidecar needed. Opt-in per namespace via label.
- **Waypoint proxy** — an optional per-namespace (or per-service-account) Envoy proxy for L7 features: retries, traffic shifting, JWT authorization. Only deployed when you need it.

```
┌─────────────────────────── node ─────────────────────────────────────┐
│                                                                       │
│  pod: api (no sidecar)         pod: db (no sidecar)                  │
│       │                              │                                │
│       └──────────── ztunnel ─────────┘    L4 mTLS, zero injection    │
│                          │                                            │
│                    waypoint proxy          optional L7 features       │
└───────────────────────────────────────────────────────────────────────┘
```

Benefits: no init-container races, lower per-pod overhead, simpler pod lifecycle. Costs: waypoints add a proxy hop for L7 features; ambient is newer and has fewer battle-tested edge cases in the field than sidecar.

---

## Data plane vs control plane

| Layer | Istio component | What it does |
|-------|----------------|-------------|
| Data plane | Envoy (per-pod sidecar) or ztunnel (per-node DaemonSet) | Proxies traffic, enforces policy, emits metrics and traces |
| Control plane | `istiod` | Pushes xDS config to Envoy, issues SPIFFE SVIDs (mTLS certs), syncs service discovery from the Kubernetes API |

`istiod` is the single control-plane binary since Istio 1.5, replacing the older Pilot + Citadel + Galley + Mixer split. It runs in `istio-system`. Every Envoy sidecar holds an open gRPC stream to `istiod` and receives xDS updates — endpoint changes, new routing rules, certificate rotations — in real time without pod restarts.

```bash
# Check the control plane
kubectl -n istio-system get pods

# Check all sidecar sync status (SYNCED = proxy is current with istiod)
istioctl proxy-status

# Dump a sidecar's current cluster config
istioctl proxy-config cluster <pod>.<ns>

# Dump a sidecar's active listeners
istioctl proxy-config listener <pod>.<ns>
```

---

## Automatic mTLS — what actually happens

mTLS = mutual TLS: both sides authenticate. In a mesh, every sidecar holds a SPIFFE SVID — a short-lived X.509 certificate issued by `istiod`'s internal CA, encoding the pod's service account as a SPIFFE URI:

```
spiffe://cluster.local/ns/dojo-payments/sa/billing
```

When pod A calls pod B:

1. Envoy on A presents its SVID to Envoy on B during the TLS handshake.
2. Envoy on B presents its SVID back.
3. Both verify the peer cert against `istiod`'s shared trust root.
4. Traffic flows over TLS 1.3. The applications send plaintext; Envoy handles TLS at both ends.

```bash
# What mTLS mode is this workload using?
istioctl authn tls-check <pod>.<ns>

# PeerAuthentication policies in a namespace
kubectl -n dojo-payments get peerauthentication -o yaml
```

### PERMISSIVE vs STRICT — the most common mesh outage

Istio's `PeerAuthentication` policy controls mTLS enforcement:

- **PERMISSIVE** (default): the sidecar accepts both mTLS and plaintext. Non-mesh clients (no sidecar) can still reach the service. Used during rollout.
- **STRICT**: requires mTLS from all callers. Rejects plaintext connections at the proxy level — the app never sees them.

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: require-mtls
  namespace: dojo-payments
spec:
  mtls:
    mode: STRICT
```

The production target is STRICT. The outage happens when you flip STRICT before every caller has a sidecar. A `kube-system` cron job, a legacy batch workload, a health-check from the node — any plaintext caller breaks.

Pre-flight checklist before flipping STRICT:

```bash
# Every workload in the namespace must show SYNCED
istioctl proxy-status | grep dojo-payments

# Check for any non-mesh callers (no sidecar annotation)
kubectl -n dojo-payments get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[*].name}{"\n"}{end}'
# Should show 'istio-proxy' alongside every app container

# Check existing mTLS status for the service
istioctl authn tls-check <pod-in-namespace>.<ns> <service-name>.dojo-payments.svc.cluster.local
```

---

## What a mesh gives you vs its cost

| Capability | With mesh | Without mesh |
|-----------|----------|-------------|
| Encrypted transit | Automatic, zero-app-change, certificate-rotated | App must implement TLS, provision and rotate certs manually |
| Service-level metrics (latency p50/p99, errors, saturation) | Automatic: Envoy emits stats; Prometheus scrapes | Instrument every service in every language with a metrics SDK |
| Distributed tracing | Automatic if app propagates trace headers | SDK integration per service per language |
| Canary / traffic splitting | VirtualService weight, no app changes, no redeploy | Custom load balancer config, language-specific client libraries |
| Retries, circuit breaking | DestinationRule, 5 lines of YAML | Custom middleware per service, per language |
| Service identity authorization (JWT, SVID) | AuthorizationPolicy CRD | Custom auth middleware per service |

Real costs — not theoretical:

- **Latency.** Two proxy hops per request (egress sidecar → ingress sidecar). Typically 1–5ms added per hop at moderate load. In a 5-service call chain: up to 10ms added to P99.
- **Resource overhead.** 50 pods with sidecars × (15–50m CPU + 64–128Mi RAM) = meaningful cluster tax on a budget node pool.
- **Operational complexity.** Istio upgrades have caused real outages when control-plane and data-plane versions are mismatched by more than one minor version. Always track both: `istioctl version`.
- **Debug surface.** When a request fails, the reason is somewhere in: app code, sidecar config, VirtualService, DestinationRule, PeerAuthentication, AuthorizationPolicy. More knobs, more places to look.

---

## Debugging Service Mesh

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Pod has only one container after enabling injection | Namespace missing `istio-injection=enabled` label | `kubectl label namespace <ns> istio-injection=enabled` then `kubectl rollout restart deploy -n <ns>` |
| Label present, sidecar still not injected | Pod/Deployment has annotation `sidecar.istio.io/inject: "false"` | Remove the opt-out annotation |
| `503 Service Unavailable` from proxy immediately | Destination not in mesh, or DestinationRule `host` typo | `istioctl proxy-config cluster <pod>.<ns> | grep <svc>` — check the cluster is listed |
| mTLS STRICT breaks existing callers | A caller has no sidecar (sends plaintext) | Verify all callers have sidecars; use `istioctl authn tls-check`; flip PERMISSIVE temporarily to identify the caller |
| Pod stuck at `Init:Error` | `istio-init` failed to set iptables (insufficient permissions) | Check `NET_ADMIN` capability on the node; inspect `kubectl logs <pod> -c istio-init` |
| `upstream connect error or disconnect/reset before headers` | Sidecar intercepts a port the app doesn't listen on | Confirm `containerPort` in the Deployment matches the app's actual listening port |
| Warnings about control-plane/data-plane version mismatch | Istiod upgraded but sidecars still running old Envoy | `kubectl rollout restart deployment --all -n <ns>` to re-inject with the current proxy version |

### Exact debugging commands

```bash
# Is the sidecar actually injected?
kubectl get pod <name> -n dojo-mesh \
  -o jsonpath='{.spec.containers[*].name}{"\n"}'
# Expected: <your-app> istio-proxy

# Why is mTLS failing? (shows TLS check per connection)
istioctl authn tls-check <pod>.<ns> <service-fqdn>

# Full proxy config dump for any sidecar
istioctl proxy-config all <pod>.<ns>

# Stream the proxy access log (one line per request)
kubectl logs -f <pod> -n dojo-mesh -c istio-proxy | tail -50

# Does the proxy know about the upstream cluster?
istioctl proxy-config cluster <pod>.<ns> --fqdn <svc>.svc.cluster.local

# Lint the entire mesh config for issues
istioctl analyze -n dojo-mesh
```

### Diagnose a 503 from Envoy

A 503 from the sidecar means Envoy couldn't forward the request — the upstream cluster was unknown, the circuit breaker opened, or the destination rejected the mTLS handshake:

```bash
# What clusters does this sidecar know about?
istioctl proxy-config cluster <pod>.<ns> | grep <upstream-svc>
# Look for STATUS=HEALTHY and matching FQDN

# Is there a DestinationRule pointing at the wrong host?
kubectl -n dojo-mesh get destinationrule -o yaml | grep host

# Check real-time proxy access log for 503 entries
kubectl logs -f <pod> -n dojo-mesh -c istio-proxy | grep '"503"'

# Full request trace from istio's point of view
istioctl proxy-config log <pod>.<ns> --level debug
```

> **War story.** During a mesh migration at SAP, we flipped a core internal API namespace to `PeerAuthentication STRICT` on a Thursday morning. Within 60 seconds, 30% of requests to that namespace started returning 503. `istioctl proxy-status` showed every workload SYNCED. The issue: a background reconciliation job running in `kube-system` was calling the API directly over HTTP with no sidecar. STRICT mode rejected the plaintext TLS handshake at the proxy level; the app never saw the request. The job had been running quietly for months — never caught in testing because our staging environment had never run with STRICT mTLS. The fix was injecting a sidecar into the kube-system DaemonSet that ran the job. But identifying that unnamed caller took 45 minutes of access-log parsing because the 503 log entry showed the source IP as a node IP, not a pod name. Since then: before flipping any namespace to STRICT, we run `istioctl authn tls-check` against every consumer of every service in that namespace, and we check `kube-system` explicitly because injection is disabled there by default.

---

## Checkpoint

You are ready for the next module when you can:

1. Describe in one paragraph what a service mesh proxy does, without naming any vendor.
2. Explain the difference between sidecar and ambient models and name one real trade-off of each.
3. Name the three things `istiod` manages (cert issuance, xDS config push, service discovery sync).
4. Explain why PERMISSIVE and STRICT mTLS produce different failure modes, and state the pre-flight check before flipping STRICT.
5. Diagnose "sidecar not injected" in exactly two commands.
6. Explain why a 503 from the proxy and a 503 from the app require different debugging paths.
7. Name three capabilities a mesh provides at zero application-code cost.

➡ Next up: **Traffic Management** — using VirtualService and DestinationRule to build canary releases, circuit breakers, and fault injection without touching application code.
