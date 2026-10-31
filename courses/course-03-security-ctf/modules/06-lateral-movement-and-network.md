# Lateral Movement & the Flat Network

> **Module 06 · Course 03** — Earlier modules landed you *inside* one pod and showed how a mounted token and loose RBAC climb the trust boundaries *outward* to the cluster. This module climbs *sideways*. By default every pod in a Kubernetes cluster can talk to every other pod, every internal Service, the kubelet, and often the node metadata endpoint — with nothing in the way. That flatness is what turns a single compromised pod into a beachhead for the whole cluster. You will enumerate that reachability the way an intruder does, pivot through a compromised pod with `netshoot`, and then shut the door with `NetworkPolicy` — including the one caveat that silently makes your policies do nothing on a stock kind cluster.

You run Kubernetes in production, so you already know pods get IPs from a cluster CIDR and Services are virtual IPs fronting endpoints. What this module is about is the thing most teams never internalize until an incident: **the pod network is allow-all until you make it deny-all.** There is no implicit firewall between namespaces, between tiers, or between a workload and the control plane. Segmentation is opt-in, and almost nobody opts in.

---

## The flat network, stated precisely

Three defaults combine into a single large blast radius:

1. **Pod-to-pod is unrestricted.** Any pod can open a connection to any other pod's IP, in any namespace, on any port the target listens on. Namespaces are an RBAC and naming boundary, **not** a network boundary.
2. **Every Service is resolvable and reachable.** CoreDNS answers for every Service in the cluster (`<svc>.<ns>.svc.cluster.local`), and the ClusterIP routes from anywhere in the pod network.
3. **The node and its neighbours are often reachable too.** The kubelet (`:10250`), the node itself, and — on a real cloud — the metadata endpoint `169.254.169.254` sit one hop away on the same flat fabric.

```
┌──────────────────── cluster pod network (one flat L3 fabric) ────────────────────┐
│                                                                                   │
│   dojo-ctf/worker ──────┬────────────▶ dojo-prod/payments   (other namespace)     │
│   (compromised)         │                                                         │
│                         ├────────────▶ kube-system/coredns  (enumerate the world) │
│                         │                                                         │
│                         ├────────────▶ node :10250 kubelet  (exec on this node)   │
│                         │                                                         │
│                         └────────────▶ 169.254.169.254      (cloud creds, on EKS) │
│                                                                                   │
│   Nothing on this diagram is blocked by default. That is the lesson.              │
└───────────────────────────────────────────────────────────────────────────────────┘
```

An attacker who lands in one pod does not need a kernel exploit to spread. They need `nslookup`, `curl`, and the knowledge that no policy is stopping them.

---

## Pivoting through a compromised pod with `netshoot`

Most application images are deliberately thin — no `dig`, no `nmap`, no `curl`. The intruder's first move is therefore to *get tools into the pod*, or to launch a tool-rich pod that sits on the same flat network. In the lab you simulate the second with `nicolaka/netshoot`, the canonical network-debug image. Pin it to a tag — never `:latest`:

```bash
kubectl -n dojo-ctf run pivot --rm -it \
  --image=nicolaka/netshoot:v0.13 --restart=Never -- bash
```

That single pod now has the same reachability as any compromised workload: it is a legitimate member of the pod network. Everything below runs from inside it.

> In a real breach the attacker rarely gets to `kubectl run` a fat image — admission control or image policy would stop that (Module 07). They instead smuggle a static `busybox`/`socat` binary into the existing pod, or use the language runtime already present (a Python `socket`, a Node `net.connect`). `netshoot` is the lab stand-in that lets you *see* the reachability without fighting tooling. The reachability it proves is identical.

---

## Step 1 — enumerate the cluster over DNS

CoreDNS is an attacker's free map. You don't need `list pods` RBAC if DNS will tell you what Services exist and where they live.

```bash
# What is my resolver and search domain? (reveals the cluster domain + my ns)
cat /etc/resolv.conf
# nameserver 10.96.0.10
# search dojo-ctf.svc.cluster.local svc.cluster.local cluster.local

# The API server is always here:
dig +short kubernetes.default.svc.cluster.local

# CoreDNS itself:
dig +short kube-dns.kube-system.svc.cluster.local
```

The high-signal trick is the **`any`-service wildcard** plus reverse lookups. A headless Service exposes every endpoint IP via DNS, and PTR records map the cluster CIDR back to pod/Service names:

```bash
# Reverse-walk the Service CIDR: every ClusterIP resolves back to its svc name.
for i in $(seq 1 20); do
  dig +short -x 10.96.0.$i | sed 's/\.$//'
done
# -> kubernetes.default.svc.cluster.local
#    kube-dns.kube-system.svc.cluster.local
#    payments.dojo-prod.svc.cluster.local   <-- a target you were never told about
```

DNS enumeration gives you the *names* of workloads in namespaces your RBAC can't even list. That is lateral recon with zero API calls.

---

## Step 2 — reach internal Services across namespaces

Having a name, you connect. Nothing stops a pod in `dojo-ctf` from hitting a Service in `dojo-prod`:

```bash
# Port-scan a discovered target (netshoot ships nmap):
nmap -Pn -p 1-10000 payments.dojo-prod.svc.cluster.local

# Talk to an internal API that assumed "only our frontend can reach me":
curl -s http://payments.dojo-prod.svc.cluster.local:8080/internal/accounts
```

The dangerous pattern this exposes: teams protect the *edge* (Ingress auth, WAF) and leave internal Services wide open because "they're only reachable from inside the cluster." On a flat network, *inside the cluster* means **every pod, including the compromised one.**

---

## Step 3 — reach the node and the metadata endpoint

Two targets escalate a sideways move into an upward one:

```bash
# Kubelet read/exec API on the node hosting you (NODE_IP from `ip route` or downward API):
NODE_IP=$(ip route | awk '/default/ {print $3}')
curl -sk https://$NODE_IP:10250/pods | head -c 400     # pod specs + env on this node
# If the kubelet allows it, /run/<ns>/<pod>/<container> is remote exec.

# Cloud metadata — the crown jewels on EKS/GKE/AKS (not present on kind, shown for realism):
curl -s --max-time 2 http://169.254.169.254/latest/meta-data/iam/security-credentials/
# -> on a real node this returns the node's IAM role; those creds are the Cloud layer.
```

This is the hinge between **Cluster** and **Cloud** in the 4 C's model from Module 01. A metadata hit from a pod is how a container breach becomes an AWS account breach. On kind there is no real metadata service, which is exactly why the course uses kind — you practice the *technique* and the *defense* without touching anything that pages someone.

---

## The defense: NetworkPolicy, default-deny first

`NetworkPolicy` is the firewall the flat network lacks. The single most important fact: **policies are additive allowlists, and they only take effect once at least one policy selects a pod.** A pod with *no* policy selecting it is allow-all; a pod selected by *any* policy is deny-all except what that (and other) policies permit. So you start by selecting everything with a deny-all, then punch precise holes.

### Default-deny the whole namespace (ingress *and* egress)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: dojo-ctf
spec:
  podSelector: {}            # selects EVERY pod in the namespace
  policyTypes:
    - Ingress
    - Egress
```

With `podSelector: {}` and no `ingress`/`egress` rules, every pod in `dojo-ctf` can now neither receive nor initiate traffic. That immediately kills Steps 1–3 above — including DNS, which you must then explicitly re-allow or nothing resolves.

### Re-allow only what the workload needs

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-and-frontend
  namespace: dojo-ctf
spec:
  podSelector:
    matchLabels:
      app: worker
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend         # only the frontend may call worker
      ports:
        - { protocol: TCP, port: 8080 }
  egress:
    - to:                           # DNS to CoreDNS — required or name resolution dies
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
```

Two things CKS candidates get wrong constantly, both visible here:

- **DNS is egress.** The moment you default-deny egress, pods can't reach CoreDNS, and *every* name lookup fails before the real connection is even attempted. You must allow UDP/TCP 53 to `kube-system/kube-dns` explicitly.
- **`namespaceSelector` + `podSelector` in one `from` entry is an AND**, not an OR. One YAML list item with both keys means "pods matching that label *in* namespaces matching that label." Split them into two list items to mean OR. This single distinction is the difference between a policy that works and one that accidentally allows the whole cluster.

### Block the node, metadata, and cross-namespace with egress allowlists

A tidy pattern for "allow the pod CIDR but deny the node/metadata/link-local ranges" is an `ipBlock` with `except`:

```yaml
  egress:
    - to:
        - ipBlock:
            cidr: 10.244.0.0/16         # the pod CIDR — intra-cluster app traffic
            except:
              - 169.254.169.254/32      # metadata endpoint — never
    # (node IPs / 10.96.0.0/12 Service CIDR allowed only where genuinely needed)
```

### Segmentation, not just per-pod rules

Per-pod allowlists are tedious at scale; the durable design is **segmentation by namespace tier**. Label namespaces (`tier: frontend|backend|data`) and write policies in terms of `namespaceSelector` so a new workload inherits the segment's rules. The goal state: a pod in `tier: frontend` can reach `tier: backend` on one port, `backend` can reach `data`, and nothing can reach the control plane or metadata. Lateral movement then costs the attacker a policy violation at every hop instead of a free ride.

---

## The caveat that eats hours: kindnet does not enforce NetworkPolicy

Here is the trap, and it is specific to your lab. **The default CNI shipped with kind — `kindnet` — provides pod networking but does *not* implement `NetworkPolicy`.** Your policy objects apply cleanly, `kubectl get netpol` shows them, `kubectl describe` looks perfect — and traffic flows anyway, because nothing is reading them. You will "test" your default-deny, watch `curl` still succeed, and conclude you wrote the policy wrong when the policy was never the problem.

```bash
# Confirm which CNI is actually enforcing. On stock kind:
kubectl -n kube-system get pods -o wide | grep -E 'kindnet|calico|cilium'
# kindnet-xxxxx  (present)  -> NetworkPolicy is NOT enforced
```

To actually enforce policy in the dojo, create the cluster with the default CNI **disabled** and install one that enforces — Calico is the usual choice:

```bash
# 1) kind config disables the built-in CNI:
#    networking: { disableDefaultCNI: true, podSubnet: "192.168.0.0/16" }
#    (then: kind create cluster --name dojo --config kind-calico.yaml)
# 2) install Calico (pin the version, never a moving ref):
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
kubectl -n kube-system rollout status ds/calico-node --timeout=120s
```

Once `calico-node` is Ready, re-apply the `default-deny-all` and watch the cross-namespace `curl` from Step 2 hang and time out. *That* is the policy working. The lesson generalizes far past the lab: **`NetworkPolicy` is only as real as the CNI enforcing it** — a managed cluster with a non-enforcing or misconfigured CNI gives you policy objects that are pure theatre.

---

## Debugging lateral movement & NetworkPolicy

NetworkPolicy failures split into two camps that look identical from the application's side (a hung connection), so you must distinguish *"my policy is blocking legitimate traffic"* from *"my policy isn't blocking anything because nothing enforces it."* Diagnose cheapest-signal first.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Applied a default-deny, but `curl` across namespaces **still works** | CNI (`kindnet`) doesn't enforce NetworkPolicy | Install an enforcing CNI (Calico) with `disableDefaultCNI: true`; confirm `calico-node` is Ready |
| All DNS lookups fail right after a default-deny egress | You didn't re-allow egress to CoreDNS on UDP/TCP 53 | Add an egress rule to `kube-system/kube-dns` for ports 53 |
| Policy "allows the whole cluster" unexpectedly | `namespaceSelector` + `podSelector` written as one `from` item (AND) when you meant OR | Split them into two separate list items under `from` |
| Legitimate frontend→backend traffic blocked after segmentation | Pod/namespace **labels** don't match the selector, or the namespace lacks `kubernetes.io/metadata.name` | Check actual labels with `kubectl get ns --show-labels` / `get pod -L app` |
| Egress rule to an external IP ignored | You used `podSelector`/`namespaceSelector` for an off-cluster target that needs `ipBlock` | Use an `ipBlock.cidr` for non-pod destinations |
| Policy applies but direction is wrong (ingress works, egress doesn't) | `policyTypes` omits `Egress`, so egress stays allow-all | List both `Ingress` and `Egress` in `policyTypes` |

### Diagnose each — the exact commands

**Is the CNI even enforcing?** This is the first question every time, because every other symptom is noise if the answer is no:

```bash
kubectl -n kube-system get pods -o wide | grep -E 'kindnet|calico|cilium'
# kindnet -> not enforced; calico-node Ready -> enforced
```

**Prove a block from the attacker's seat.** Launch the pivot pod and test reachability directly — a timeout is a working deny, `Connection refused` is a *different* problem (nothing listening), and success is a hole:

```bash
kubectl -n dojo-ctf run probe --rm -it --image=nicolaka/netshoot:v0.13 --restart=Never -- \
  sh -c 'curl -s --max-time 4 http://payments.dojo-prod.svc.cluster.local:8080/ || echo BLOCKED'
# BLOCKED (hang→timeout) = policy enforced.  immediate reply = still open.
```

**Read what actually selects a pod.** A policy that selects nothing enforces nothing:

```bash
kubectl -n dojo-ctf get netpol
kubectl -n dojo-ctf describe netpol default-deny-all      # shows selected pods + rules
kubectl -n dojo-ctf get pods -L app                       # do the labels match the selector?
kubectl get ns --show-labels                              # is kubernetes.io/metadata.name present?
```

**Confirm DNS specifically**, because a dead resolver masquerades as "everything is blocked":

```bash
kubectl -n dojo-ctf run dnstest --rm -it --image=nicolaka/netshoot:v0.13 --restart=Never -- \
  sh -c 'dig +short kubernetes.default.svc.cluster.local || echo DNS-DEAD'
```

If this prints `DNS-DEAD` the instant after you applied a default-deny, you forgot the port-53 egress allow — not a connectivity bug, a policy omission.

> **War story.** On the LGTM log pipeline at SAP we rolled a namespace-wide default-deny into a pre-prod cluster to segment the ingest tier from the query tier. CI went green, the policies `describe`'d perfectly, and we shipped. Twenty minutes later the on-call got paged: Loki queriers couldn't reach the compactor, but *only in one cluster*. The policy was identical everywhere. The difference was the CNI — one cluster ran Calico, the pre-prod one still ran a non-enforcing default from an old bootstrap. In the enforcing cluster our default-deny had silently killed egress to CoreDNS (we'd never allowed port 53), so every Loki component failed name resolution and fell back to cached endpoints that drifted. The non-enforcing cluster had "passed" our test only because *no policy there did anything at all*. Two bugs hiding each other: a missing DNS egress rule, and a test that validated against a CNI that ignored the thing we were testing. The fix was two lines of egress YAML and a hard assertion in bootstrap that `calico-node` is Ready before any policy applies. Lesson burned in: **a NetworkPolicy you haven't watched *block* real traffic on the *enforcing* CNI is an untested NetworkPolicy.**

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. State in one sentence why namespaces are not a network boundary, and what *is*.
2. Explain the NetworkPolicy additive-allowlist rule: what a pod selected by zero policies can do, versus one selected by any policy.
3. Write a namespace-wide default-deny for both ingress and egress from memory.
4. Name the one egress rule you must *always* add after a default-deny, and explain what breaks if you forget it.
5. Explain the difference between `namespaceSelector` and `podSelector` as two list items (OR) versus one item with both keys (AND), and why it matters.
6. Enumerate cluster Services from inside a pod using only DNS, with no `list` RBAC.
7. Describe the pivot from a compromised pod to the kubelet (`:10250`) and to `169.254.169.254`, and which 4 C's boundary each crosses.
8. State the kindnet caveat in one sentence and the command that tells you whether your CNI enforces policy at all.
9. Prove a NetworkPolicy block from the attacker's seat using a `netshoot` pod and distinguish a timeout (enforced) from `Connection refused` (nothing listening).

➡ Next up: **Defense in Depth: Hardening Checklist** — you'll stack NetworkPolicy together with Pod Security Admission, seccomp, read-only rootfs, image provenance, and admission policy into one consolidated checklist, and learn to diagnose a hardened pod that won't start *without* re-opening the hole you just closed.
