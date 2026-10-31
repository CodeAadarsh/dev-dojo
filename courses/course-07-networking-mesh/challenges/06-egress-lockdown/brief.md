# Egress Lockdown

A compliance audit found that every pod in `dojo-egress` can reach the internet — including the S3 bucket that stores customer backups. The finding: no egress NetworkPolicy means a compromised pod can exfiltrate data to any destination, and to any internal namespace it chooses.

You need to implement a **default-deny egress** posture and then carve out exactly the egress paths the service legitimately needs: DNS resolution (so nothing else breaks) and one specific destination.

## Background: NetworkPolicy egress

A `NetworkPolicy` is only enforced if your CNI plugin supports it (Calico, Cilium, Weave — but **not** the default `kindnet`). On a stock `kind` cluster, policies are accepted by the API server but silently have no effect. For real enforcement on kind, install Calico:

```bash
# Replace kindnet with Calico (run once after cluster creation)
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml
```

This challenge authors the correct policy objects regardless — the verifier checks the authored resources, not live traffic.

The two key pieces of NetworkPolicy egress:

| Field | What it does |
|-------|-------------|
| `spec.policyTypes: [Egress]` | Declares this policy governs outgoing traffic from matched pods |
| `spec.egress` | Whitelist of permitted destinations. An empty list `[]` combined with `policyTypes: [Egress]` = **deny all egress** |

A **default-deny** policy matches all pods (empty `podSelector: {}`) and has `policyTypes: [Egress]` with no `egress` rules. Then you add a *separate* allow policy for the paths you need — or add the allow rules to the same policy.

## Mission

Author two NetworkPolicy resources in namespace `dojo-egress`:

### 1. `default-deny-egress` — deny all egress

```
podSelector: {}          # all pods
policyTypes: [Egress]
egress: []               # no rules = deny all
```

### 2. `allow-dns-and-monitoring` — allow DNS + one destination

Allow:
- **DNS** (port 53, both UDP and TCP) to namespace `kube-system`
- **Monitoring endpoint** (port 9090, TCP) to namespace `dojo-monitoring` (or any namespace with label `purpose: monitoring`)

The verifier checks:
1. A NetworkPolicy with `policyTypes` including `Egress` exists in `dojo-egress`.
2. At least one egress rule allowing port 53 exists in any NetworkPolicy in that namespace.

No CNI enforcement is required — the verifier inspects the authored objects only.
