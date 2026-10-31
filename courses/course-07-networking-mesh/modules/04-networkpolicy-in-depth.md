# NetworkPolicy in Depth

> **Module 04 · Course 07** — By default, every pod in your cluster can talk to every other pod, across any namespace, on any port. That's the default-allow model, and it's lateral-movement paradise. This module explains how to lock it down, why the semantics are additive-only, and why most NetworkPolicy tutorials on the internet are quietly wrong because the CNI they used doesn't enforce anything.

You've probably written a NetworkPolicy before. This module is about the gaps: the AND-vs-OR trap in peer selectors, the DNS egress everyone forgets, the kindnet enforcement hole, and the one fact about additive semantics that means you can never "accidentally deny" with more policies.

---

## The default-allow problem

No NetworkPolicy applied to a pod = no restrictions. Every pod gets a cluster-routable IP; any pod can open a TCP connection to any other pod on any port. A compromised frontend pod can reach your database pods, your CI agent, your etcd's HTTP port — anything reachable by IP inside the cluster.

```
┌──────── dojo-frontend ─────────┐   ┌──────── dojo-payments ──────────┐
│  pod: web     10.244.1.10      │   │  pod: billing  10.244.2.5       │
│  pod: static  10.244.1.11      │◄──┤  pod: worker   10.244.2.6       │
└────────────────────────────────┘   └─────────────────────────────────┘
          ▲                                           ▲
          │  reachable by any pod with no policy     │
          └──────────── dojo-debug: netshoot ────────┘
```

The consequence of lateral movement: an RCE in a public-facing pod gives an attacker connectivity to everything. NetworkPolicy is your east-west firewall inside the cluster.

### The selection rule

A NetworkPolicy selects pods via `spec.podSelector`. The semantics when a policy selects a pod:

> Once a NetworkPolicy selects a pod *and covers a direction* (Ingress or Egress), all traffic in that direction that is not explicitly listed in any policy is dropped.

A pod with zero policies: allow all. A pod selected by one or more policies: allow only the explicit union of what those policies permit, in each covered direction.

---

## Ingress vs egress — independently scoped

A NetworkPolicy covers `Ingress`, `Egress`, or both via `policyTypes`. Each direction is independent:

- **Ingress** — controls what other pods/CIDRs may initiate connections *to* the selected pods.
- **Egress** — controls what the selected pods may initiate connections *to*.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-policy
  namespace: dojo-netpol
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              role: frontend
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - protocol: TCP
          port: 5432
    - to:                          # CoreDNS egress — always required
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

The DNS rule at the bottom is not optional — see the debugging section.

---

## Peer selectors: podSelector, namespaceSelector, ipBlock

NetworkPolicy offers three types of peer expression for the `from` and `to` lists.

### podSelector

Matches pods by label within the **same namespace** as the NetworkPolicy:

```yaml
from:
  - podSelector:
      matchLabels:
        app: frontend
```

### namespaceSelector

Matches all pods in namespaces that carry the given labels. The label goes on the Namespace object:

```yaml
from:
  - namespaceSelector:
      matchLabels:
        team: platform
```

Since Kubernetes 1.21, every namespace gets `kubernetes.io/metadata.name: <name>` automatically — use it for exact namespace matching without adding custom labels:

```yaml
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: dojo-monitoring
```

### ipBlock

Allows specific CIDR ranges, with an optional `except` list. Use it for external load balancers, on-prem monitoring scrapers, or trusted external CIDRs:

```yaml
from:
  - ipBlock:
      cidr: 10.0.0.0/8
      except:
        - 10.0.0.1/32   # exclude a specific node IP
```

---

## The AND-vs-OR trap in combined selectors

This is where mistakes happen. Two entries in the array are **ORed**. Two fields on the same entry are **ANDed**. The YAML indentation is load-bearing.

```yaml
# OR: allows traffic from (pods with app=web) OR (pods in a namespace labeled team=platform)
from:
  - podSelector:
      matchLabels:
        app: web
  - namespaceSelector:
      matchLabels:
        team: platform

# AND: allows traffic ONLY from pods with app=web that are in a namespace labeled team=platform
from:
  - podSelector:
      matchLabels:
        app: web
    namespaceSelector:
      matchLabels:
        team: platform
```

The OR form (two list entries) is almost always what you want for cross-namespace rules. The AND form (two fields on one entry) is what you need when you want to pin to a specific pod inside a specific namespace without opening the whole namespace.

---

## Default-deny patterns

### Default-deny all ingress in a namespace

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: dojo-netpol
spec:
  podSelector: {}      # empty = selects ALL pods in the namespace
  policyTypes:
    - Ingress
  # no ingress rules = deny all ingress to all selected pods
```

### Default-deny all egress in a namespace

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: dojo-netpol
spec:
  podSelector: {}
  policyTypes:
    - Egress
  # no egress rules = deny all egress
```

### Default-deny everything (strictest baseline)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: dojo-netpol
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

**The recommended pattern:** apply default-deny-all first, then add targeted allow policies for each workload. Because semantics are additive, you cannot accidentally re-deny something by layering policies — each new policy can only add permissions.

---

## The kindnet enforcement gap — why your policies are probably a no-op

The NetworkPolicy API is a Kubernetes standard. **Enforcement is delegated to the CNI plugin.** Not every CNI implements it.

kind's default CNI is **kindnet** — a minimal overlay for connectivity. It routes packets but does **not** interpret NetworkPolicy objects. You can apply a default-deny-all policy and a pod on a kindnet cluster will still reach anything it wants. The API accepts the object; the enforcement just never happens.

```bash
# Demonstrate: apply deny-all, then probe anyway
kubectl -n dojo-netpol apply -f default-deny-all.yaml
kubectl run probe --rm -it --restart=Never \
  --image=nicolaka/netshoot:v0.13 -- \
  curl -m 3 http://api.dojo-netpol.svc.cluster.local:8080
# On a kindnet cluster: 200 OK. Policy silently ignored.
```

To get real enforcement in kind labs, use **Calico**. Replace kindnet when creating the cluster:

```bash
# Create a cluster with Calico from the start (disables kindnet in kind config)
bash labs/bootstrap/create-cluster-calico.sh

# Verify Calico daemonset is up
kubectl -n kube-system get pods -l k8s-app=calico-node -o wide
```

Or retrofit an existing kind cluster:

```bash
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
kubectl -n kube-system rollout status daemonset/calico-node
# Wait for all calico-node pods to be Running before testing policy
```

Once Calico is running, reapply your NetworkPolicy objects — now the iptables rules backing each policy will be written by `calico-node` onto every node.

---

## Additive (union) semantics — you can never "deny" by adding

Multiple NetworkPolicies can select the same pod. Their allowed traffic sets are **unioned**:

- Policy A: allow ingress from `app=frontend`.
- Policy B: allow ingress from `app=monitoring`.
- Result: pod accepts traffic from both. There is no interaction, no precedence, no "most specific wins."

This means:

- **Adding** a policy can only widen permissions.
- **Narrowing** permissions requires modifying or deleting an existing policy.
- There is no `effect: Deny` in a NetworkPolicy rule — denial is the absence of an allow.

```bash
# List all policies in a namespace and who they select
kubectl -n dojo-netpol get netpol

# See the full selector + rules for a specific policy
kubectl -n dojo-netpol describe netpol api-policy
```

---

## Debugging NetworkPolicy

Three questions cover almost every failure: Is the CNI actually enforcing? Is the policy selecting the right pods? Is DNS broken?

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Policy applied, traffic still flows freely | CNI (kindnet) doesn't enforce NetworkPolicy | Replace with Calico; verify with `kubectl -n kube-system get pods -l k8s-app=calico-node` |
| All DNS resolution fails after adding egress policy | DNS egress to `kube-system` port 53 not whitelisted | Add egress rule: `namespaceSelector: kubernetes.io/metadata.name: kube-system`, ports 53 UDP+TCP |
| Pod can't reach same-namespace peers despite allow rule | Namespace label mismatch in `namespaceSelector` | `kubectl get ns --show-labels` — verify the label used in the policy actually exists on the namespace |
| Monitoring pod blocked despite an allow rule | `podSelector` has a typo or different label key than the actual pod | `kubectl -n <ns> get pods --show-labels` and compare exactly to the `from` podSelector |
| Traffic blocked in both directions, policy covers only one | `policyTypes` lists `Ingress` but not `Egress`; once Egress is covered (by another policy), unlisted egress is dropped | Add `Egress` to `policyTypes` and write explicit egress rules |
| `kubectl apply` succeeds but policy has no effect at all | Applied to the wrong namespace (forgot `-n`) | `kubectl get netpol -A` to find where the policy actually landed |

### Exact debugging commands

```bash
# Is Calico (the enforcer) actually running?
kubectl -n kube-system get pods -l k8s-app=calico-node -o wide

# Which policies select pods in a namespace?
kubectl -n dojo-netpol get netpol -o yaml

# Test connectivity from inside the cluster network
kubectl run probe --rm -it --restart=Never \
  --image=nicolaka/netshoot:v0.13 -- \
  curl -m 3 http://api.dojo-netpol.svc.cluster.local:8080

# Is DNS resolution working? (tests UDP 53 egress)
kubectl run probe --rm -it --restart=Never \
  --image=busybox:1.36 -- \
  nslookup kubernetes.default.svc.cluster.local

# Check what labels pods actually carry (vs what policy selects)
kubectl -n dojo-netpol get pods --show-labels

# Check what labels namespaces carry (for namespaceSelector debugging)
kubectl get ns --show-labels
```

### DNS egress — the failure everyone hits first

You add a default-deny-egress policy. Within seconds, pods in the namespace stop resolving names. The error in the app looks like a connection failure to your target service, not a DNS error — because the DNS step happens first and silently fails.

```bash
# Confirm DNS is the actual problem
kubectl exec -it <pod> -n dojo-netpol -- nslookup api.dojo-netpol.svc.cluster.local
# -> timeout or SERVFAIL means DNS egress is blocked, not the target

# The required egress rule to add alongside every default-deny-egress:
cat <<'YAML'
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
  ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
YAML
```

CoreDNS pods live in `kube-system`. Without UDP/TCP 53 egress to `kube-system`, no DNS. Include that rule in every egress policy template as a non-negotiable baseline.

> **War story.** Migrating a set of microservices to a stricter namespace in the SAP AI Core pipeline, I wrote a careful default-deny-egress with explicit allow entries for every upstream service. Rolled it out in staging — everything broke. gRPC calls to internal services timed out, but the services themselves were up and healthy. Took 30 minutes before someone ran `nslookup` inside an affected pod and saw `SERVFAIL`. We had forgotten to whitelist egress to `kube-system` port 53. Every service was trying to connect, but the DNS resolution step that happens before the TCP SYN was being silently dropped. The timeout errors from gRPC looked exactly like the target was down — completely misleading. Since then, every default-deny-egress template in our repo has the DNS rule as the first entry, marked with a comment that reads "NEVER REMOVE THIS."

---

## Checkpoint

You are ready for the challenges when you can:

1. Explain the default-allow model and state the exact rule that changes once a NetworkPolicy selects a pod.
2. Write a default-deny-all policy and explain why no explicit deny rules are needed.
3. Distinguish AND-vs-OR peer selector semantics by YAML structure alone, without looking it up.
4. State which CNI kind uses by default, why it matters for NetworkPolicy, and the exact fix.
5. Write the DNS egress rule and explain at what layer it breaks when missing.
6. Diagnose "policy applied, traffic still flows" in two steps.
7. Use `kubectl run probe` with `nicolaka/netshoot:v0.13` to test connectivity from inside the cluster's network namespace.

➡ Next up: **Service Mesh** — when NetworkPolicy is too coarse-grained and you need per-connection mTLS, identity-based authorization, and traffic control without touching application code.
