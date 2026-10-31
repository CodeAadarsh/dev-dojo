# Default Deny, Then Allow

The security team ran a lateral-movement exercise and found that every pod in every namespace could reach every other pod — because the cluster had **no NetworkPolicies**. In a flat network, a single compromised pod is game over for every other workload on the cluster.

The remediation is the single most important networking primitive: **default deny everything, then allow exactly what you mean to allow.**

## Prerequisites

**Calico is strongly recommended for real enforcement** — kind's default CNI (`kindnet`) does not enforce NetworkPolicy in its standard configuration. If you are using kindnet, the objects will be accepted by the API server and the verifier will pass, but actual traffic between pods will not be blocked. To install Calico on your kind cluster:

```bash
# Use the kube-dojo bootstrap script (it patches kindnet out and installs Calico):
bash labs/bootstrap/install-calico.sh
```

If you want the verifier-only path (authoring correctness without live enforcement), kindnet is sufficient.

## Scenario

The setup script creates namespace `dojo-np` with:
- A `backend` Deployment (nginx, port 80) — label `role=backend`.
- A `client` Deployment (busybox sleep) — label `role=client`. This represents a rogue pod that should NOT reach the backend after you apply the policies.
- A Service `backend-svc` on port 80 targeting the backend pods.

Out of the box, the client pod can curl the backend. Your job is to lock that down.

## Mission

Create **two** NetworkPolicy objects in namespace `dojo-np`:

1. **`default-deny-ingress`** — a catch-all deny for all ingress traffic to every pod in the namespace:
   - `podSelector: {}` (matches all pods)
   - `policyTypes: [Ingress]`
   - No `ingress:` rules (empty = deny all)

2. **`allow-frontend-to-backend`** — a targeted allow so pods with `role=frontend` can reach the backend on port 80:
   - `podSelector: {matchLabels: {role: backend}}` (protects the backend)
   - One ingress rule from `podSelector: {matchLabels: {role: frontend}}` on port 80

## Target state (what verify.sh checks)

1. A NetworkPolicy named `default-deny-ingress` exists in `dojo-np` with `podSelector: {}` and `policyTypes` containing `Ingress`.
2. A NetworkPolicy named `allow-frontend-to-backend` exists in `dojo-np` with `podSelector.matchLabels.role = backend`.
3. The allow policy has at least one ingress rule from a `podSelector` matching `role=frontend` on port 80.

## Why this matters

A default-deny policy is the difference between a breach that's contained to one pod and one that laterally moves to your entire cluster's workloads. The key insight: **a NetworkPolicy does not replace firewall rules at the node level** — it is enforced by the CNI plugin (Calico, Cilium, etc.) at the virtual network interface of each pod. Without a CNI that understands NetworkPolicy, the objects exist but do nothing.
