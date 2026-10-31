# Solution — Egress Lockdown

Two NetworkPolicy manifests: one to deny all egress, one to allow DNS and monitoring.

```yaml
# default-deny-egress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: dojo-egress
spec:
  podSelector: {}        # applies to ALL pods in the namespace
  policyTypes:
    - Egress
  egress: []             # empty list = deny all egress
---
# allow-dns-and-monitoring.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-and-monitoring
  namespace: dojo-egress
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    # DNS: allow UDP + TCP port 53 to kube-system (CoreDNS)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
    # Monitoring: allow TCP 9090 to any namespace labelled purpose=monitoring
    - to:
        - namespaceSelector:
            matchLabels:
              purpose: monitoring
      ports:
        - port: 9090
          protocol: TCP
```

Apply and verify:

```bash
kubectl apply -f default-deny-egress.yaml -f allow-dns-and-monitoring.yaml
bash courses/course-07-networking-mesh/challenges/06-egress-lockdown/verify.sh
```

## Why each piece matters

**Empty `egress: []` + `policyTypes: [Egress]` is the deny-all pattern.** Without `policyTypes: [Egress]`, a policy with an empty `egress` field is ignored for egress — the `policyTypes` field is what tells the CNI to enforce egress. An easy trap: omitting `policyTypes` and wondering why traffic still flows.

**DNS MUST be explicitly allowed, or nothing works.** Locking egress without carving out port 53 breaks all DNS lookups. Pods can no longer resolve `kubernetes.default.svc.cluster.local`, CoreDNS becomes unreachable, and every outbound connection silently times out. This is the most common "I applied a NetworkPolicy and broke everything" moment in production. Both UDP and TCP must be allowed — DNS uses UDP for queries under 512 bytes and falls back to TCP for large responses (EDNS0, zone transfers). Missing TCP means occasional DNS failures that are hard to reproduce.

**`namespaceSelector` by label is more robust than CIDR.** CoreDNS pod IPs change when you recreate the cluster. Using `kubernetes.io/metadata.name: kube-system` (a label Kubernetes auto-applies to every namespace since 1.21) stays correct through IP changes.

## Attacker's view

With no egress policy, a compromised pod can:
- Reach any internal service in any namespace (east-west exfiltration)
- Reach the internet directly (C2 callback, data exfiltration to S3/Pastebin)
- Probe the EC2 instance metadata endpoint (`169.254.169.254`) to harvest cloud credentials

With the deny-all policy in place, a compromised pod is limited to the explicit allow-list. DNS leakage is still possible over port 53 (DNS tunnel exfiltration) — the next hardening step is a DNS egress proxy that inspects queries and blocks non-allowlisted domains.

## Debugging NetworkPolicy

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Policy applied, traffic still flows | CNI doesn't support NetworkPolicy (kindnet) | Install Calico or Cilium |
| Everything broken after apply | Missing DNS allow rule | Add port 53 UDP+TCP to kube-system |
| Specific service unreachable | Namespace label mismatch | `kubectl get ns <ns> --show-labels` and cross-check the selector |
| Policy appears correct but drops unexpected traffic | `policyTypes` missing `Egress` | Add `policyTypes: [Egress]` explicitly |

```bash
# Confirm policy is stored correctly
kubectl -n dojo-egress get networkpolicies -o yaml

# Check if CoreDNS namespace has the expected label
kubectl get ns kube-system --show-labels | grep 'kubernetes.io/metadata.name'

# From inside a pod (if you have CNI enforcement), test DNS resolution
kubectl run -n dojo-egress --rm -it probe --image=nicolaka/netshoot -- \
  dig kubernetes.default.svc.cluster.local
```
