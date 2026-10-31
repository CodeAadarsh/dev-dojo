# The Kubernetes Threat Model & Attacker Toolkit

> **Module 01 · Course 03** — Courses 01–02 taught you to make clusters *survive*. To defend against a real intrusion you have to understand how one is structured: where the trust boundaries are, how a single compromised pod is *supposed* to be contained, and which signals tell a defender the containment failed. This module is the threat map. Everything here exists so you can harden the boundary — you cannot defend a path you cannot see.

You run Kubernetes in production, so you know the control-plane components. What separates a competent operator from someone who can defend a cluster is thinking in **trust boundaries** and **escalation paths** — not "what does this component do" but "what is the blast radius when it's misconfigured, and which boundary should have contained it."

---

## The 4 C's — the nested model of cloud-native security

Cloud-native security nests like Russian dolls. A weakness in an outer layer undermines everything inside it; a weakness in an inner layer is *contained* only if the outer layers are sound. This is the mental model the whole course defends.

```
┌──────────────────────── Cloud / Datacenter ────────────────────────┐
│  IAM, VPC, node metadata endpoint (169.254.169.254), API endpoint   │
│  ┌──────────────────────── Cluster ────────────────────────────┐    │
│  │  API server, etcd, kubelet, RBAC, admission, NetworkPolicy   │    │
│  │  ┌──────────────────── Container ──────────────────────┐     │    │
│  │  │  image contents, runtime user, caps, seccomp, SA     │     │    │
│  │  │  ┌──────────────── Code ────────────────────────┐    │     │    │
│  │  │  │  app logic, dependencies, secrets-in-env      │    │     │    │
│  │  │  └───────────────────────────────────────────────┘   │     │    │
│  │  └──────────────────────────────────────────────────────┘     │    │
│  └────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
```

| Layer | What a defender protects | Why it's the weak link when ignored |
|-------|--------------------------|-------------------------------------|
| **Code** | App logic, dependencies | A vulnerable dependency is the most common initial foothold |
| **Container** | `securityContext`, image provenance | A loose `privileged`/`hostPath` turns a pod breach into a node breach |
| **Cluster** | RBAC, admission, SA tokens | Over-broad RBAC turns a pod breach into a cluster breach |
| **Cloud** | IAM, network, metadata | Node credentials reachable from a pod turn a cluster breach into an account breach |

The key insight for defenders: an intrusion almost never *starts* where it ends up. It starts in **Code** (an application bug) and climbs outward. Each layer is a chance to stop the climb.

---

## The cluster attack surface — reachability and authentication

These are the components an intrusion probes. For each, the defender asks the same two questions: **is it reachable from where an attacker lands, and does it properly authenticate the caller?**

```
            ┌─────────────────────────────────────────────────┐
  internet  │  Ingress / LoadBalancer  ── your apps            │
  ───────▶  │                                                  │
            │  :6443  kube-apiserver   ◀── RBAC gate           │
            │  :2379  etcd             ◀── every Secret at rest│
  in-pod    │  :10250 kubelet API      ◀── must require auth   │
  ───────▶  │  :443   dashboard        ◀── only if deployed    │
            │  SA token /var/run/secrets/... ◀── in EVERY pod  │
            └─────────────────────────────────────────────────┘
```

- **API server (`:6443`)** — the front door. Every request is authenticated (client cert, bearer token, or OIDC) and then authorized by RBAC. The thing a defender must minimize is any credential that RBAC treats as *more* privileged than its workload needs.
- **kubelet (`:10250`)** — the per-node agent. Its API can `exec` into pods on that node and stream logs. If deployed with `--anonymous-auth=true` or `--authorization-mode=AlwaysAllow`, a caller that reaches it skips RBAC entirely. The deprecated read-only port `:10255` leaks pod specs and env when left on. Defenders ensure Webhook authz is enabled and the port is unreachable from workloads.
- **etcd (`:2379`)** — the source of truth. Every object, including every Secret (base64-encoded, **not** encrypted unless you enabled encryption-at-rest), lives here. Node-level access to etcd bypasses RBAC completely, which is exactly why node access and encryption-at-rest both matter.
- **Dashboard** — the classic cryptojacking entry point from the 2018 Tesla incident. An exposed dashboard, or one backed by an over-powered ServiceAccount, is a GUI onto the cluster. Modern guidance: don't deploy it, or gate it behind auth and minimal RBAC.
- **ServiceAccount tokens** — the surface that surprises teams who feel safe. **Every pod receives a mounted SA token by default** unless it opts out. That token is a bearer credential to the API server. If the pod's SA holds more RBAC than it needs, a compromised app inherits that RBAC. This is the subject of this course's first challenge — and the fix is `automountServiceAccountToken: false` plus least-privilege Roles.
- **Registries / supply chain** — a poisoned base image or typosquatted dependency is untrusted code running before your app logic even starts. Image signing and admission verification close this.

> **Mental model:** the API server trusts *credentials*, not people. A token is a token. The whole cluster-layer game is: a credential leaks, and it turns out to be worth more than it should be. Least privilege shrinks that worth to near-zero.

---

## The pod-to-cluster escalation path

This chain is the spine of the entire course, because defending each link is what every later module hardens:

```
  application bug                            ← Code
        │  code now runs inside a pod
        ▼
  mounted SA token + ca.crt is readable      ← Container
  /var/run/secrets/kubernetes.io/serviceaccount/
        │  the token authenticates to the API server
        ▼
  kubectl auth can-i --list   (self-audit)   ← Cluster
        │  reveals whatever RBAC the SA was granted
        ▼
  over-broad RBAC → read Secrets / make pods ← Cluster
        │  e.g. a pod that mounts hostPath /
        ▼
  weak securityContext → node filesystem     ← Node
        │  node kubeconfig / cloud metadata creds
        ▼
  other nodes, then the cloud account         ← Cloud
```

Every arrow is a boundary that *should* have stopped the climb, and each has a concrete control:

| Boundary crossed | Control that stops it |
|------------------|-----------------------|
| Pod reads cluster Secrets | Least-privilege RBAC; `automountServiceAccountToken: false` |
| Pod creates a privileged pod | Pod Security Admission (`restricted`), Kyverno/OPA |
| Pod reaches kubelet / etcd / metadata | NetworkPolicy egress rules |
| Container reaches node filesystem | `securityContext`: non-root, drop caps, `readOnlyRootFilesystem`, seccomp |

When one link holds, the chain breaks. That is defense-in-depth stated concretely, and it's why a single misconfiguration is rarely catastrophic on a well-built cluster.

---

## Recon the way a defender should audit

The reconnaissance an intruder performs from a pod is identical to the self-audit *you* should run against your own workloads. Run these against your production ServiceAccounts and you will find permissions nobody remembers granting.

```bash
# Who does the API server think this pod's SA is? (reads the mounted token)
kubectl auth whoami

# The single most valuable audit command — list this credential's permissions:
kubectl auth can-i --list

# Targeted questions:
kubectl auth can-i get secrets -n dojo-ctf
kubectl auth can-i create pods
kubectl auth can-i '*' '*'            # is this SA effectively cluster-admin?
```

`kubectl auth can-i --list` drives the API server's `SelfSubjectRulesReview` to dump every verb/resource the current credential can touch. It is the attacker's map and the defender's audit tool — the same API, opposite intent.

Most workload images don't ship `kubectl`. The mounted token still authenticates over plain HTTPS, which is the mechanic the first challenge drills — and the reason defenders scope tokens tightly:

```bash
SA=/var/run/secrets/kubernetes.io/serviceaccount
TOKEN=$(cat "$SA/token")
NS=$(cat "$SA/namespace")

# Call the API directly: trust the cluster CA, present the bearer token.
curl --cacert "$SA/ca.crt" \
  -H "Authorization: Bearer $TOKEN" \
  "https://kubernetes.default.svc/api/v1/namespaces/$NS/secrets"
```

The three files in that directory — `token`, `ca.crt`, `namespace` — are everything needed to be a first-class API client. Knowing they're always there (unless you disabled automounting) is the whole point.

---

## The toolkit — and what each tool reveals

You don't need exotic tooling to understand the threat; you need to recognize the names, because they appear in postmortems and CKS material alike.

| Tool | What it is | Defensive use |
|------|-----------|---------------|
| **`nicolaka/netshoot`** | A debug image full of network tools (`dig`, `curl`, `nmap`, `tcpdump`) | Confirm that a NetworkPolicy actually blocks pod→kubelet / pod→metadata egress |
| **`kubeletctl`** (concept) | A client that speaks the kubelet `:10250` API directly | Validate that your kubelets reject anonymous and unauthorized calls |
| **`kube-hunter`** (concept) | Scans a cluster for known exposure (open ports, tokens, dashboard) | Run it against your own cluster to find what an outsider would see first |
| **`kube-bench`** (concept) | Checks the node/control-plane against the CIS Kubernetes Benchmark | Turn its findings into a hardening checklist — it maps 1:1 to real misconfigs |

`kube-bench` and `kube-hunter` are the two you should actually run on any cluster you own. `kube-bench` tells you where you deviate from the CIS benchmark (anonymous auth, insecure ports, missing audit logging); `kube-hunter` tells you what's reachable. Between them they surface most of the attack surface drawn above before anyone else finds it.

> **Keep the balanced framing:** every offensive technique in this course maps to exactly one defensive control. You learn the escalation path so you can place the control that breaks it. A defender who has never traced the climb tends to harden the wrong link.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Name the 4 C's and give one concrete control at each layer.
2. List the four high-value components on the cluster attack surface and the one question that matters for each (reachable? authenticated?).
3. Recite the pod-to-cluster escalation path and name the control that breaks each link.
4. Explain why `automountServiceAccountToken: false` plus least-privilege RBAC is the core mitigation for a compromised pod.
5. Read a ServiceAccount token, CA cert, and namespace out of a pod and craft a `curl` that authenticates to the API server.

➡ Next up: the **Stolen ServiceAccount Token** challenge — you'll land in a pod, discover its mounted token, authenticate to the API server by hand, and read a Secret its ServiceAccount was granted more access to than it should have been.
