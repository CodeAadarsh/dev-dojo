# Pivot Through the Pod

A backend team built an `internal-api` with no authentication. Their reasoning, written in the design doc: *"It's only reachable from inside the cluster — the frontend calls it over the private Service, and nothing external can route to it."* The edge is locked down tight: Ingress auth, a WAF, TLS everywhere. The internal API is wide open, because "inside the cluster" was assumed to mean "trusted."

You've just landed a shell in an unrelated pod — `foothold`, a compromised throwaway workload in the *same namespace*. You have no credentials, no token worth stealing, no node access. All you have is a network interface on the cluster's pod fabric. On a default Kubernetes install, **that is enough**, because the pod network is allow-all until someone makes it deny-all — and almost nobody does.

## The scenario the setup script plants

| Object | Detail |
|--------|--------|
| Namespace `dojo-lateral` | No NetworkPolicy anywhere — the network is flat and allow-all |
| Deployment `internal-api` | `nginx:1.27-alpine` serving a page that contains `FLAG=KUBE{...}` on port 80 |
| Service `internal-api` | `ClusterIP` fronting the Deployment — resolvable cluster-wide via CoreDNS |
| Pod `foothold` | `nicolaka/netshoot:v0.13`, sleeping — your beachhead, on the same flat network |

```
┌──────────── dojo-lateral — one flat L3 fabric, zero policy ────────────┐
│                                                                        │
│   foothold  ───── curl :80 ─────▶  internal-api (ClusterIP)            │
│  (compromised)                      "only the frontend can reach me"   │
│                                                                        │
│   nothing on this path is blocked. namespaces are not a firewall.      │
└────────────────────────────────────────────────────────────────────────┘
```

## Mission

From inside the `foothold` pod, reach the `internal-api` Service and read the flag it serves. The internal API "trusted" that only its frontend could reach it — prove that trust is unfounded on a flat network.

Legitimate routes (try more than one — each is real intruder tradecraft):

1. **Resolve and curl the Service by DNS name** — `internal-api.dojo-lateral.svc.cluster.local`.
2. **Enumerate first, then connect** — use CoreDNS and a port scan to *discover* the target the way an attacker who wasn't told it exists would.
3. **Hit the ClusterIP directly** if you prefer to skip name resolution.

Submit the `KUBE{...}` flag the API returns.

## Why this matters

Three defaults combine into one large blast radius, and this challenge is the argument for closing all three:

- **Pod-to-pod traffic is unrestricted.** Any pod can open a connection to any other pod or Service, in any namespace. A namespace is an RBAC and naming boundary, **not** a network boundary.
- **Every Service is discoverable.** CoreDNS answers for every Service in the cluster, so an attacker maps your internal topology with `dig`, needing no `list` RBAC at all.
- **Internal services assume the network is a wall.** It isn't. "Reachable only from inside the cluster" means reachable from *every* pod, including the one the attacker owns.

The fix is a **default-deny `NetworkPolicy`** that flips the namespace from allow-all to deny-all, after which you punch precise, auditable holes. You'll write it in the solution — along with the one caveat that makes `NetworkPolicy` silently do nothing on a stock kind cluster.
