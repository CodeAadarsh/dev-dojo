# Exposed Kubelet & API Surfaces

> **Module 03 · Course 03** — Module 02 was about escalating *inside* the API server's authorization: a credential that RBAC trusted too much. This module is about the surfaces that let a caller **skip the API server entirely**. The kubelet on every node speaks its own HTTP API on `:10250` — it can `exec` into pods, stream logs, and list everything running on that node, and if it's configured to trust anonymous callers, none of that goes through RBAC. You'll map the kubelet's API, trace the API server's own authentication chain, and internalize the sentence this whole course keeps returning to: **node access is cluster access.**

You run nodes in production, so you know the kubelet exists. What separates operating nodes from defending them is understanding the kubelet as an *independent, internet-RFC HTTP server* with its own authn/authz knobs — one that, misconfigured, is a second unguarded door into every pod on the node. The 2018 crypto-mining campaigns that hit Kubernetes clusters didn't break the API server; many walked in through kubelets left on `--anonymous-auth=true`.

---

## The node as its own attack surface

A node isn't just where pods run — it's a host with several listening services, each a potential entry point. On a kind cluster, the "node" is a container, so you can inspect all of this with `docker exec`.

```
┌──────────────────────── a node (kind: a container) ──────────────────────────┐
│                                                                               │
│   :10250  kubelet API (HTTPS)   ── /pods /exec /run /logs /runningpods ...     │
│   :10255  kubelet read-only     ── DEPRECATED, no auth, leaks pod specs+env    │
│   :10256  kube-proxy healthz                                                   │
│            containerd / CRI socket  /run/containerd/containerd.sock            │
│            every pod's filesystem + its mounted SA token                       │
│            /var/lib/kubelet/pods/.../volumes/...secret.../token                │
│            node kubeconfig (control-plane): /etc/kubernetes/*.conf             │
│            static pod manifests: /etc/kubernetes/manifests/*.yaml              │
│            on the control-plane node ALSO: etcd data + PKI under /etc/kubernetes/pki │
└───────────────────────────────────────────────────────────────────────────────┘
```

| Surface | Port / path | What it exposes | Auth by default (modern k8s) |
|---------|-------------|-----------------|------------------------------|
| kubelet API | `:10250` HTTPS | exec/run/logs/port-forward, pod + node state | **requires** authn + authz (Webhook) — but must be *configured* |
| kubelet read-only | `:10255` HTTP | pod list with full specs incl. env | off by default now; catastrophic when on — **no auth at all** |
| CRI socket | unix socket | `crictl` to every container on the node | file-permission gated — root on node = full control |
| SA tokens on disk | `/var/lib/kubelet/pods/...` | every mounted token of every pod on the node | file perms — node root reads all of them |
| control-plane PKI | `/etc/kubernetes/pki` | CA keys, SA signing key, etcd certs | node root — this is **game over** for the cluster |

The progression is the point: reach the kubelet → exec into pods → read their tokens → or reach the node's filesystem → read the node kubeconfig and (on the control-plane) the signing keys. Each step needs only the one before it.

---

## The kubelet API — a second door into every pod

The kubelet authenticates and authorizes requests to `:10250` **independently of the API server**. It has its own two-stage gate:

```
   caller ──▶ :10250 ──▶ [ authentication ]  who are you?
                              │  x509 client cert  (--client-ca-file)
                              │  bearer token      (--authentication-token-webhook)
                              │  ANONYMOUS         (--anonymous-auth=true)  ◀── the bug
                              ▼
                         [ authorization ]  are you allowed?
                              │  Webhook  -> asks the API server (SubjectAccessReview)
                              │  AlwaysAllow  ◀── the other bug
                              ▼
                         /exec /run /logs /pods ...
```

Two independent misconfigurations each fully open the door:

- **`--anonymous-auth=true`** — the kubelet accepts unauthenticated requests as the user `system:anonymous` in group `system:unauthenticated`. Authentication is now a no-op.
- **`--authorization-mode=AlwaysAllow`** — the kubelet authorizes *everything* it authenticates. Authorization is now a no-op.

Either alone is bad; together they mean *anyone who can reach `:10250` can exec into any pod on that node as root-in-container*. The secure pairing is `--anonymous-auth=false` **and** `--authorization-mode=Webhook`, which delegates every decision to the API server's RBAC (the kubelet asks "can this identity do `nodes/proxy`?" via `SubjectAccessReview`).

What a reachable, weakly-authed kubelet gives an attacker:

```bash
# Enumerate everything running on the node — pod names, namespaces, containers,
# AND the env of each container (which routinely holds secrets mounted as env):
curl -sk https://NODE_IP:10250/pods | tr ',' '\n' | grep -iE 'name|namespace'

# Run a command in a specific container WITHOUT touching the API server / RBAC:
#   POST /run/{namespace}/{pod}/{container}  with  cmd=...
curl -sk -X POST \
  "https://NODE_IP:10250/run/dojo-ctf/worker/worker" \
  -d "cmd=cat /var/run/secrets/kubernetes.io/serviceaccount/token"
# -> prints the pod's SA token. Now you have a credential AND you never hit RBAC to get it.
```

That second call is the whole lesson: the kubelet will execute in a pod's container for you, and that container holds a ServiceAccount token. **A weak kubelet is a token-harvesting machine** — it hands you exactly the credentials Module 01 and 02 taught you to escalate with. The deprecated read-only `:10255` is even cheaper: a plain `curl http://NODE_IP:10255/pods` dumps every pod spec, env vars included, with no auth whatsoever.

---

## The API server auth chain — for contrast

The API server on `:6443` is the surface people *think* about, and it's the well-guarded one. Understanding its chain makes the kubelet's missing links obvious.

```
  request ──▶ [ TLS ] ──▶ [ Authentication ] ──▶ [ Authorization ] ──▶ [ Admission ] ──▶ etcd
                               │                       │                     │
                        client cert /           RBAC / Node /          validating +
                        bearer token /          Webhook /              mutating webhooks,
                        OIDC / webhook          ABAC                   Pod Security Admission
```

| Stage | Question | What breaks it |
|-------|----------|----------------|
| Authentication | who is this credential? | `--anonymous-auth=true` on the API server (lets `system:anonymous` in) |
| Authorization | may they do this? | an over-broad RBAC grant (Module 02) |
| Admission | should this specific object be allowed? | no Pod Security Admission / no policy engine |

The kubelet is a *miniature* of this same chain — authn then authz — but with far weaker defaults historically and a much smaller blast-radius-per-mistake audience, which is exactly why it gets overlooked. The two questions a defender asks every surface (from Module 01) apply identically: **is it reachable, and does it properly authenticate the caller?** For the kubelet, "reachable" means "can a pod or an off-cluster host open a TCP connection to `:10250`," and the answer should be *no* for workloads — enforced by NetworkPolicy and host firewalling.

---

## Node access = cluster access

This is the sentence to tattoo on the inside of your eyelids. Once you're root on a node — whether via a weak kubelet that exec'd you in, a container escape (next challenge territory), or a `hostPath` mount — the cluster's trust model collapses, because the node legitimately holds cluster credentials:

```
  root on a WORKER node
     ├─ read every pod's SA token under /var/lib/kubelet/pods/.../token
     │     -> replay the most privileged one against :6443
     ├─ read the node's own kubelet client cert (/var/lib/kubelet/pki/)
     │     -> the Node authorizer lets a kubelet read Secrets of pods scheduled to it
     └─ crictl / containerd socket -> exec in ANY container on the node

  root on the CONTROL-PLANE node  (on kind: dojo-control-plane)
     ├─ /etc/kubernetes/admin.conf        -> a cluster-admin kubeconfig, handed to you
     ├─ /etc/kubernetes/pki/ca.key        -> MINT any client cert = any identity, forever
     ├─ /etc/kubernetes/pki/sa.key        -> FORGE ServiceAccount tokens for any SA
     └─ etcd data dir                     -> every Secret in the cluster, directly
```

The control-plane row is why `--anonymous-auth=true` on a control-plane node's kubelet is apocalyptic: one unauthenticated `/run` into any pod on that node, then read `admin.conf` off the host mount, and the attacker *is* the cluster. There is no RBAC left to stop them — they have the CA signing key and can mint a cert for `system:masters`.

> **Why the Node authorizer is a feature, not the bug.** Real kubelets *must* read the Secrets, ConfigMaps, and PV data of the pods scheduled onto their node — that's how volumes get populated. The **Node authorization mode** scopes each kubelet to exactly the objects its own pods reference, using the `system:node:<nodename>` identity. It's genuinely least-privilege for a legitimate kubelet. The danger isn't the Node authorizer; it's a *human* or *workload* obtaining a kubelet's identity, or a kubelet that authorizes anonymous callers as if they were the kubelet.

---

## The DEFENSE — shut both doors

Every attack above closes under a small, specific set of controls. These are CIS-benchmark items you can check on any cluster you own.

**1. Kubelet authn/authz — the non-negotiable pair.** In the kubelet config (`/var/lib/kubelet/config.yaml` on a real node):

```yaml
# KubeletConfiguration — the secure baseline
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false            # (1) no system:anonymous — close the no-authn door
  webhook:
    enabled: true             # bearer tokens validated via TokenReview
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook               # (2) every request authorized by API-server RBAC
readOnlyPort: 0               # (3) kill the deprecated unauthenticated :10255
```

The three lines that matter: `anonymous.enabled: false`, `authorization.mode: Webhook`, `readOnlyPort: 0`. kind sets sane defaults here (anonymous off, Webhook on), which is why the recon below returns `401`/`403` rather than pod data — that's the control working, and you'll verify it.

**2. Firewall / NetworkPolicy so workloads can't reach `:10250`.** Defense in depth: even a perfectly-authed kubelet shouldn't be *reachable* from application pods. Deny pod egress to node IPs on the kubelet port:

```yaml
# Deny app pods from dialing any node's kubelet. (CNI must enforce NetworkPolicy;
# kind's default kindnet does not — install Calico/Cilium to actually enforce this.)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-kubelet-egress
  namespace: dojo-node
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]   # block RFC1918 node IPs
    - ports:                        # still allow DNS + API server as needed
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
```

**3. RBAC on `nodes/proxy`.** The API server exposes the kubelet *through* itself at `/api/v1/nodes/<node>/proxy/...`. The verb that matters is `nodes/proxy` — granting it is granting kubelet-level exec:

```bash
# Who can proxy to kubelets (i.e. exec on any node) cluster-wide?
kubectl auth can-i --list --as=system:serviceaccount:dojo-node:someapp | grep -i 'nodes/proxy'
```

Treat `create` on `nodes/proxy` as equivalent to node root, and grant it to nothing but monitoring/debug tooling that provably needs it.

**4. `automountServiceAccountToken: false`** (again). Every mitigation from Module 01 compounds here: a kubelet that exec's an attacker into a pod only yields a token if the pod *has* one mounted. No token, no credential to harvest.

> **Keep the balanced framing:** the kubelet API is load-bearing — `kubectl exec`, `kubectl logs`, and `kubectl port-forward` all ride it via the API server. You're not disabling it; you're ensuring every call is authenticated, authorized by RBAC, and unreachable except through the front door on `:6443`.

---

## Debugging Exposed Kubelet & API Surfaces

Node-surface debugging is mostly *verification*: proving a port is unreachable or properly authed, and reading the kubelet's own config when it misbehaves. On kind, every node is a container, so the golden rule from Course 01 applies double here: **when the kubelet is the question, `docker exec` into the node and read its config and logs directly.**

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `curl -k https://NODE:10250/pods` returns pod JSON to an unauthenticated caller | `--anonymous-auth=true` **and** `AlwaysAllow` | set `anonymous.enabled: false` + `authorization.mode: Webhook`, restart kubelet |
| `curl http://NODE:10255/pods` returns data | deprecated read-only port is on | set `readOnlyPort: 0` |
| `401 Unauthorized` from `:10250` anon | authentication is doing its job | this is correct — present a valid cert/token to proceed as a legit client |
| `403 Forbidden` from `:10250` with a token | authn passed, Webhook authz denied | correct behavior; the identity lacks `nodes/proxy` — grant narrowly only if required |
| A pod can open a TCP connection to a node's `:10250` at all | no NetworkPolicy egress restriction / permissive CNI | add egress policy; confirm CNI enforces it (kindnet does **not**) |
| `kubectl exec`/`logs` broken cluster-wide after a kubelet change | kubelet authz webhook can't reach the API server, or cert expired | check kubelet logs; verify `clientCAFile` and webhook config |
| App SA shows `nodes/proxy` in `can-i --list` | over-broad ClusterRole | remove `nodes/proxy`; it's node-root-equivalent |

### Diagnose each — the exact commands (on kind)

**Find the node's IP and probe the kubelet the way an attacker would.** The node IP is the kind container's IP:

```bash
# The control-plane node's container IP on the kind network:
NODE_IP=$(docker inspect dojo-control-plane \
  -o '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
echo "$NODE_IP"

# Anonymous probe — on a hardened kubelet this is 401 (authn) or 403 (authz). That's the win:
curl -sk -o /dev/null -w '%{http_code}\n' "https://$NODE_IP:10250/pods"     # expect 401/403
curl -s  -o /dev/null -w '%{http_code}\n' "http://$NODE_IP:10255/pods"      # expect connection refused (port off)
```

**Read the kubelet's actual config to confirm the knobs.** Don't trust assumptions — read the file inside the node:

```bash
# kind runs the kubelet as a systemd unit inside the node container.
docker exec dojo-control-plane cat /var/lib/kubelet/config.yaml \
  | grep -A2 -iE 'anonymous|authorization|readOnlyPort|webhook'

# Kubelet logs (systemd unit) — how it authenticated/authorized a call, and startup flags:
docker exec dojo-control-plane journalctl -u kubelet --no-pager | tail -40
docker exec dojo-control-plane sh -c 'cat /proc/$(pidof kubelet)/cmdline | tr "\0" " "; echo'
```

**Node-level recon with `crictl` (the legitimate version of the attacker's `/run`).** Once you're root on the node — which `docker exec` gives you on kind — `crictl` talks straight to the CRI socket, no kubelet API and no RBAC involved:

```bash
docker exec dojo-control-plane crictl ps                 # every container on the node
docker exec dojo-control-plane crictl pods               # every pod sandbox
# Inspect a container's env (where env-mounted secrets live) and its mounts:
CID=$(docker exec dojo-control-plane sh -c "crictl ps -q --name worker | head -1")
docker exec dojo-control-plane crictl inspect "$CID" | grep -iE 'KUBE|TOKEN|mountPath' | head
```

**Prove the reachability control.** The highest-value check: can a *workload pod* even open the port? Spin up a throwaway netshoot pod and try:

```bash
kubectl -n dojo-node run probe --rm -it --restart=Never \
  --image=nicolaka/netshoot:v0.13 -- \
  sh -c "nc -zv -w2 $NODE_IP 10250; echo rc=$?"
# "succeeded"/rc=0 means the port is reachable from workloads -> you need the egress NetworkPolicy.
# "timed out"/refused means firewalling/policy is doing its job.
```

**Find the signing keys an attacker would race for (so you can confirm they're node-root-only).** On the control-plane node:

```bash
docker exec dojo-control-plane ls -l /etc/kubernetes/pki/ca.key /etc/kubernetes/pki/sa.key /etc/kubernetes/admin.conf
# These must be root-owned, 0600. Anyone who reads ca.key can mint a cert for ANY identity;
# anyone who reads sa.key can forge a token for ANY ServiceAccount. That's why node root = cluster.
```

> **War story.** Doing a CIS sweep on a pre-prod cluster at SAP, `kube-hunter` flagged an open `:10250` on the worker nodes. The kubelets were *authenticated* (good) but the node security group let the entire pod CIDR dial `:10250` directly — so any compromised app pod could skip the API server and ask a kubelet to `/run` a command in a neighboring pod, harvesting its token. The kubelet auth was fine; the *reachability* was the hole, and nobody had modeled "pod → kubelet" as an egress path because the diagrams only ever drew "pod → API server." We added an egress NetworkPolicy denying RFC1918 node IPs on `:10250` and tightened the security group, then re-ran the netshoot probe until it timed out. The lesson: **"the kubelet requires auth" and "the kubelet is unreachable from workloads" are two different controls, and you need both — auth is the lock, reachability is whether the door is even in the attacker's hallway.**

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Name the kubelet's two independent gates (authentication, authorization) and the flag that neuters each (`--anonymous-auth=true`, `--authorization-mode=AlwaysAllow`).
2. State the secure pairing (`anonymous.enabled: false` + `authorization.mode: Webhook`) and what `Webhook` delegates to.
3. Explain why `readOnlyPort: 0` matters and what `:10255` leaks when left on.
4. Describe how a weak kubelet becomes a ServiceAccount-token-harvesting machine via `/run` or `/pods`.
5. Walk the API server's four-stage chain (TLS → authn → authz → admission) and say which kubelet stages are its weaker mirror.
6. Justify "node access = cluster access" by naming what root on a *control-plane* node can read (`admin.conf`, `ca.key`, `sa.key`, etcd).
7. Explain why the **Node authorizer** is least-privilege for a real kubelet yet catastrophic for an attacker wearing a kubelet identity.
8. Identify `nodes/proxy` in a `can-i --list` and explain why it's node-root-equivalent.
9. On kind, read a node's live kubelet config and flags with `docker exec ... cat /var/lib/kubelet/config.yaml` and `/proc/<pid>/cmdline`.
10. Probe `:10250`/`:10255` with `curl` and a netshoot pod, and correctly read `401`/`403`/`refused`/`timed out` as the control working.

➡ Next up: the course's challenges put all three modules together — you'll stand up the escalation chain end to end, from a stolen token through over-broad RBAC to node-level access, and then slam each door shut with the controls you just mapped.
