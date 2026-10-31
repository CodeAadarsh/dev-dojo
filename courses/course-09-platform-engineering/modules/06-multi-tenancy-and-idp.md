# Multi-Tenancy & Internal Developer Platforms

> **Module 06 · Course 09** — A cluster shared by multiple teams is a cluster looking for an incident. Not because teams are malicious — because the blast radius of "my pod requesting 64 CPUs" isn't scoped to the requester. Multi-tenancy is the set of controls that turns shared infrastructure into something as safe as siloed infrastructure, without the per-team cluster cost.

This module covers the enforcement layer (ResourceQuota, LimitRange, RBAC, NetworkPolicy per tenant), the hierarchy tools that scale it (HNC), and the self-service layer that makes it invisible to developers (golden paths, Backstage). These components are what separate "we have Kubernetes" from "we have a platform."

---

## Namespace-as-a-tenant: the fundamental model

The simplest K8s multi-tenancy model: each team gets one or more namespaces, and per-namespace controls enforce isolation. No VM boundary, no cluster-per-team — just namespaces with the right objects inside them.

```
cluster
├── namespace: team-alpha
│     ├── ResourceQuota  — hard cap on total resources (cpu, memory, pods, PVCs)
│     ├── LimitRange     — per-container defaults + maximums
│     ├── Role + RoleBinding — scoped permissions for team members
│     ├── NetworkPolicy  — deny ingress/egress from other namespaces by default
│     └── workloads...
│
├── namespace: team-beta
│     └── (same controls, different limits)
│
└── kube-system (platform team only)
```

The risk: **none of these controls are automatic.** A new namespace without a `ResourceQuota` has unlimited resource allocation. A namespace without a `NetworkPolicy` accepts traffic from any pod in the cluster. The platform team's job is to ensure every tenant namespace is born with all four controls — which is exactly what Kyverno `generate` and hierarchical namespaces automate.

---

## ResourceQuota

A `ResourceQuota` sets hard limits on total resource consumption for a namespace:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-alpha-quota
  namespace: team-alpha
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "20"
    services: "10"
    persistentvolumeclaims: "5"
    secrets: "30"
    configmaps: "20"
    count/deployments.apps: "10"
```

Key enforcement behaviour: when a `ResourceQuota` specifying CPU or memory exists in a namespace, **every pod must have resource `requests` set** or the API server rejects it. This is intentional — quota accounting requires explicit request values. The side-effect is that you get forced discipline on resource sizing. Use a `LimitRange` to provide defaults so teams don't have to type requests on every container.

```bash
kubectl -n team-alpha describe resourcequota team-alpha-quota
# NAME               AGE   REQUEST                                   LIMIT
# team-alpha-quota   5d    requests.cpu: 1/4, requests.memory: 2Gi/8Gi

# See exactly what the quota is counting
kubectl -n team-alpha get resourcequota team-alpha-quota -o yaml | grep -A20 "status:"
```

When a deployment fails because of quota, the error is explicit:

```
Error from server (Forbidden): pods "web-5d9f4bxxx" is forbidden:
  exceeded quota: team-alpha-quota,
  requested: requests.memory=512Mi,
  used: requests.memory=7.75Gi,
  limited: requests.memory=8Gi
```

One trap: **completed Jobs leave pods in `Succeeded` phase that still count against the pod quota.** Clean them up:

```bash
kubectl -n team-alpha delete pods --field-selector=status.phase=Succeeded
```

Another trap: **Deployments scaled to 0 don't delete their ReplicaSets**, and if a ReplicaSet has `replicas=1` in its spec, it still consumes quota (even though no pod is running). Check:

```bash
kubectl -n team-alpha get replicasets -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas'
```

---

## LimitRange

A `LimitRange` sets per-container defaults and maximums — it's the "sane defaults" complement to the "hard caps" of `ResourceQuota`:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: team-alpha-limits
  namespace: team-alpha
spec:
  limits:
    - type: Container
      default:           # injected as limits if container doesn't specify them
        cpu: 200m
        memory: 256Mi
      defaultRequest:    # injected as requests if container doesn't specify them
        cpu: 50m
        memory: 64Mi
      max:               # container cannot exceed
        cpu: "2"
        memory: 2Gi
      min:               # container must request at least
        cpu: 10m
        memory: 16Mi
    - type: Pod
      max:
        cpu: "4"
        memory: 4Gi
    - type: PersistentVolumeClaim
      max:
        storage: 10Gi
```

The `default` and `defaultRequest` values are injected by the API server's admission controller *before* the `ResourceQuota` check runs. A pod submitted without any resource fields gets `cpu: 50m / memory: 64Mi` requests and `cpu: 200m / memory: 256Mi` limits automatically. Without this, a `ResourceQuota` that requires requests would break every deployment that doesn't set them.

The operational contract: LimitRange provides defaults, ResourceQuota enforces totals. Both are required for a usable multi-tenant namespace.

---

## RBAC per tenant

Scope permissions to the namespace, not the cluster:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: developer
  namespace: team-alpha
rules:
  - apiGroups: ["", "apps", "batch", "networking.k8s.io", "autoscaling"]
    resources:
      ["pods", "deployments", "replicasets", "services",
       "configmaps", "jobs", "cronjobs", "horizontalpodautoscalers", "ingresses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["pods/exec", "pods/log", "pods/portforward"]
    verbs: ["create", "get"]
  # secrets intentionally omitted — teams consume secrets through apps, not by reading them
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: alpha-devs
  namespace: team-alpha
subjects:
  - kind: Group
    name: team-alpha    # OIDC group claim from your IdP
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: developer
  apiGroup: rbac.authorization.k8s.io
```

A `RoleBinding` can reference a `ClusterRole` (using `roleRef.kind: ClusterRole`) — this gives the ClusterRole's permissions *scoped to the namespace only*. The built-in `edit` ClusterRole is often the right base for a developer binding, plus explicit denials via a separate `Role` for anything `edit` grants that you don't want (like `secrets`).

Audit who can do what in a namespace:

```bash
kubectl auth can-i --list -n team-alpha --as=system:serviceaccount:team-alpha:app-runner
kubectl get rolebindings,clusterrolebindings -n team-alpha -o wide
```

---

## NetworkPolicy per tenant

The default cluster network allows all pod-to-pod traffic, across namespaces. A NetworkPolicy changes that:

```yaml
# Start with deny-all
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: team-alpha
spec:
  podSelector: {}    # applies to all pods in the namespace
  policyTypes:
    - Ingress
    - Egress
---
# Allow intra-namespace traffic (same namespace, no namespaceSelector = current ns)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: team-alpha
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector: {}
  egress:
    - to:
        - podSelector: {}
    - ports:
        - port: 53
          protocol: UDP    # DNS — CoreDNS is in kube-system
        - port: 53
          protocol: TCP
---
# Allow egress to specific cross-namespace services (e.g., platform API gateway)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-platform-egress
  namespace: team-alpha
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: platform-system
          podSelector:
            matchLabels:
              app: api-gateway
      ports:
        - port: 443
```

The pattern: `default-deny-all`, then explicit allowlisting. Every new communication path requires a policy change — which forces teams to consciously document their inter-service dependencies.

> **CNI is the enforcement layer.** `NetworkPolicy` objects are stored in etcd and enforced by the CNI plugin — not by Kubernetes itself. kind ships with `kindnet`, which supports NetworkPolicy enforcement. Calico, Cilium, and Antrea also enforce it. **Flannel does not** — a Flannel cluster silently accepts your NetworkPolicy YAML but never enforces it. Always verify enforcement with a test pod after creating policies.

Verify a NetworkPolicy is actually enforced:

```bash
# Plant a test pod in team-beta and attempt to reach team-alpha
ALPHA_POD_IP=$(kubectl -n team-alpha get pod -o jsonpath='{.items[0].status.podIP}')
kubectl -n team-beta run test --rm -it \
  --image=nicolaka/netshoot:v0.12 --restart=Never -- \
  nc -zv -w3 "$ALPHA_POD_IP" 80
# Should print: "nc: connect to ... timed out" if NetworkPolicy is working
```

---

## Hierarchical Namespace Controller (HNC)

HNC solves: a team needs multiple namespaces (one per service), and every one needs the same quota/RBAC/NetworkPolicy. Without HNC, you'd duplicate those objects.

HNC introduces a parent-child namespace tree. Objects in the parent are propagated to child namespaces and kept in sync:

```bash
# Install HNC
kubectl apply -f https://github.com/kubernetes-sigs/hierarchical-namespaces/releases/download/v1.1.0/default.yaml

# Create the parent namespace
kubectl create namespace team-alpha

# Create child namespaces via SubnamespaceAnchors placed in the parent
kubectl -n team-alpha apply -f - <<'EOF'
apiVersion: hnc.x-k8s.io/v1alpha2
kind: SubnamespaceAnchor
metadata:
  namespace: team-alpha
  name: team-alpha-auth
EOF

kubectl hns tree team-alpha
# team-alpha
# ├── team-alpha-auth
# └── team-alpha-billing
```

Objects labelled for propagation in `team-alpha` (RoleBindings, NetworkPolicies, LimitRanges) are automatically copied to `team-alpha-auth` and kept in sync. A single `RoleBinding` in the parent covers all children — this is the 10x multiplier HNC provides on a large platform.

The risk: **overly permissive objects in the parent propagate to every child.** If the parent's `RoleBinding` grants `cluster-admin`, every child namespace inherits it. Scope parent permissions carefully, and use `HierarchyConfiguration` to exclude specific objects from propagation where needed.

---

## Internal Developer Platforms & golden paths

An IDP is the operational layer between "raw cluster" and "developer makes a request." The golden path is the set of defaults, guardrails, and self-service workflows that make the right thing the easy thing.

### What a golden path looks like

```
Developer → Backstage service catalog
     │  fills a software template: team name, service name, compute tier
     │
     ▼
scaffolding creates:
  • Git repo (from template)
  • ArgoCD Application (auto-deploy on merge)
  • Kubernetes namespace with:
      - ResourceQuota (computed from compute tier input)
      - LimitRange (platform defaults)
      - RBAC (team group from OIDC)
      - NetworkPolicy (default-deny + allowlist from service metadata)
      - ServiceMonitor (Prometheus scrape target auto-created)
```

Nothing is magic — it's automation of the manual checklist every new service needs. The discipline is: **every service goes through the same path**, so nothing ships without quota, monitoring, or RBAC. The platform team encodes good defaults into the template; developers never have to think about them.

### Backstage at one level of depth

Backstage (Spotify's open-source IDP framework) is a React + Node.js app you self-host. The key abstractions for platform engineering:

- **Catalog:** a registry of every service, API, team, and resource. K8s Services + ArgoCD Applications + Crossplane Claims all register here via entity providers.
- **Software Templates:** the golden path scaffolder. A template defines input fields and `fetch:template` + `publish:github` + `argocd:create-app` steps.
- **Plugins:** the extension model (TechDocs, Kubernetes live pod status, Grafana panels embedded in the catalog page).

The three platform engineering principles that make Backstage work:

1. **Templatize, don't doc.** If you have a runbook step, it should be a template action.
2. **Encode defaults in the template, not team instructions.** The template applies the LimitRange and NetworkPolicy — the developer never sees them and doesn't have to care.
3. **Escape hatches, not walls.** A golden path without escape hatches is a golden cage. Teams must be able to deviate with a label and a policy exception — then audit overrides with Kyverno `Audit` mode.

---

## Debugging multi-tenancy

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Pod creation fails: `exceeded quota: requested: ...` | Namespace has consumed its ResourceQuota hard limit | `kubectl -n <ns> describe resourcequota` — identify the exhausted resource; clean up idle pods/RSets or raise the quota |
| Pod creation fails: `pods "<name>" is forbidden: [must specify requests for cpu]` | ResourceQuota requires requests but pod has none, and no LimitRange defaultRequest | Add a `LimitRange` with `defaultRequest` to the namespace — this is the missing default injector |
| Container is heavily CPU-throttled despite low utilization | CPU `limit` set far below burst capacity; kernel CFS throttle fires | `kubectl top pod -n team-alpha --containers`; if usage < request but >> limit, raise `limits.cpu` or remove the limit entirely (requests give scheduling fairness, limits cause throttle) |
| Pods from another team's namespace can reach this namespace's pods | NetworkPolicy exists but CNI doesn't enforce it (Flannel), or policy selector is too permissive | Verify CNI with `kubectl -n kube-system get pods | grep cni`; test enforcement with `nc -zv` from a cross-namespace debug pod |
| HNC-propagated RoleBinding grants too much to child namespaces | Parent has a broad `ClusterRole` ref; children inherit it | Narrow the parent Role; use `HierarchyConfiguration` to mark specific RoleBindings as non-propagating |
| New namespace has no quota | Provisioning script is missing the ResourceQuota creation step | Add a Kyverno `generate` policy: on `Namespace` creation, auto-generate `ResourceQuota` + `LimitRange` |
| `kubectl top pod` shows one pod consuming 80% of node CPU | No CPU `limit` set; pod gets burst CPU at the expense of neighbours | Set `limits.cpu` on the container; or raise the node count; the noisy neighbour problem is a missing-limits problem |

### Diagnose each — the exact commands

**Noisy-neighbour CPU starvation:**

```bash
# Find the top CPU consumers across the cluster
kubectl top pods -A --sort-by=cpu | head -20

# Is the team hitting their quota?
kubectl -n team-alpha describe resourcequota

# Show all containers' requests vs limits
kubectl -n team-alpha get pods -o custom-columns=\
'NAME:.metadata.name,CPU_REQ:.spec.containers[0].resources.requests.cpu,CPU_LIM:.spec.containers[0].resources.limits.cpu,MEM_REQ:.spec.containers[0].resources.requests.memory'
```

**Quota exhaustion — find the waste:**

```bash
# ReplicaSets with desired=1 but no running pods (Deployment scaled to 0)
kubectl -n team-alpha get replicasets \
  -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas'

# Completed Job pods still counting toward pod quota
kubectl -n team-alpha get pods --field-selector=status.phase=Succeeded
kubectl -n team-alpha delete pods --field-selector=status.phase=Succeeded
```

**Cross-namespace network leak check:**

```bash
# List namespaces that have NO NetworkPolicy at all — these are open
kubectl get networkpolicy -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' \
  | sort -u > /tmp/has_netpol.txt
kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
  | grep dojo- > /tmp/all_ns.txt
comm -23 /tmp/all_ns.txt /tmp/has_netpol.txt   # namespaces with no NetworkPolicy

# Test cross-namespace reachability
BETA_IP=$(kubectl -n team-beta get pod -o jsonpath='{.items[0].status.podIP}')
kubectl -n team-alpha run probe --rm -it \
  --image=nicolaka/netshoot:v0.12 --restart=Never -- \
  nc -zv -w3 "$BETA_IP" 80
```

> **War story.** During an LGTM observability stack rollout at SAP, a newly created namespace for a logging sidecar service had no ResourceQuota — the provisioning script had a conditional that skipped quota creation for "infrastructure" namespaces. A load test ran and that namespace's pods requested 32 GiB total across its containers, which pushed the node past its memory limit. The kernel OOM reaper started evicting pods from *other* teams' namespaces on the same node — three teams' services went down without any change on their side. The incident took two hours to root-cause because the symptom (OOMKilled pods in team-alpha) pointed nowhere near the cause (runaway pods in a different namespace on the same node). The fix: Kyverno `generate` policy that auto-creates ResourceQuota + LimitRange on every namespace with a `team` or `owner` label, making missing quota physically impossible.

---

## Checkpoint

You're ready for the challenge when you can, without looking anything up:

1. Explain the relationship between `ResourceQuota` and `LimitRange` — which forces you to set requests, and which provides defaults so you don't have to?
2. Write the `kubectl` command to see how much CPU quota a namespace has consumed vs its limit.
3. Explain why NetworkPolicy enforcement depends on the CNI, and name two CNIs that enforce it.
4. Describe the HNC `SubnamespaceAnchor` pattern — what does it create, and what propagates?
5. Name the four controls that should be present in every tenant namespace at creation.
6. Explain why a Deployment scaled to 0 can still contribute to pod quota consumption.
7. Describe the `default-deny-all` + explicit-allowlist NetworkPolicy pattern — why start with deny?
8. State the one-line kyverno generate policy pattern that ensures new namespaces always get a ResourceQuota.

➡ Next up: the **Tenant Namespace** challenge — you'll provision a namespace with ResourceQuota, LimitRange, and a scoped RoleBinding, and the verifier confirms all three are correctly configured.
