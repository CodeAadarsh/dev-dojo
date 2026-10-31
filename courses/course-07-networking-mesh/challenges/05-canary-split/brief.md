# Canary Traffic Split

Your team just shipped `app:v2` — a rewrite of the payment summary service. Before rolling it out fully, the PM wants to shadow-test it under real traffic: 10 % of requests routed to v2, 90 % still on v1. If error rates are clean after an hour, the ratio flips.

You need to wire this up in the Istio service mesh using a `VirtualService` and a `DestinationRule` — the standard Istio canary pattern.

## Background: how Istio traffic shifting works

```
Client → Service (ClusterIP) → Envoy sidecar (source pod)
                                        │
                              VirtualService rule
                                 ┌──────┴───────┐
                                 │              │
                               90 %           10 %
                                 │              │
                           subset: v1      subset: v2
                                 │              │
                           DestinationRule defines which pods are v1 vs v2
                           (via pod labels)
```

The `DestinationRule` defines *named subsets* (e.g. `v1`, `v2`) — each is a label selector into the backing pods. The `VirtualService` references those subset names and assigns weights. This separation keeps traffic policy (`VirtualService`) decoupled from identity policy (`DestinationRule`).

> **PREREQ:** Istio must be installed on the cluster.
>
> Install Istio (if not present):
> ```bash
> curl -L https://istio.io/downloadIstio | sh -
> istioctl install --set profile=demo -y
> ```
> Namespace `dojo-canary` will be created by the setup script with two app versions pre-deployed.

## Mission

The setup script plants:

- Namespace `dojo-canary` (with `istio-injection=enabled`)
- Deployment `app-v1` (label `version: v1`, 2 replicas)
- Deployment `app-v2` (label `version: v2`, 1 replica)
- Service `app` selecting all pods with `app: myapp`

Author the following two objects:

### 1. DestinationRule `app` in `dojo-canary`

- Host: `app` (the ClusterIP service name)
- Two subsets:
  - name `v1`, labels `version: v1`
  - name `v2`, labels `version: v2`

### 2. VirtualService `app` in `dojo-canary`

- Hosts: `["app"]`
- HTTP route with two weighted destinations:
  - `subset: v1`, weight `90`
  - `subset: v2`, weight `10`

The verifier checks:
1. A `VirtualService` named `app` exists in `dojo-canary` with two route destinations whose weights sum to 100.
2. A `DestinationRule` named `app` exists in `dojo-canary` with at least two subsets.

The weights must sum to exactly 100 — Istio requires this and the verifier enforces it.
