# CNI & CRI: Networking and the Runtime

> **Module 03 · Course 05** — The scheduler bound the pod to `dojo-worker`. Now the kubelet on that node has to turn a PodSpec into running containers with a working IP. Two pluggable interfaces make that happen: the **CRI** (how the kubelet starts containers) and the **CNI** (how a pod gets onto the network). This module takes you down to `crictl` on the node and into the pod's own network namespace — the layer where `ContainerCreating` either resolves or hangs forever.

Everything above this module spoke in abstractions — Pods, Deployments, Services. Down here there are no such things. There are Linux namespaces, a container runtime, a bridge, and some iptables rules. Kubernetes is a convention layered on top of boring Linux primitives, and this is where you see the seams.

---

## The CRI: how the kubelet runs containers

The kubelet does not contain Docker, or any runtime. It speaks the **Container Runtime Interface** — a gRPC API — to whatever runtime the node runs. On `kind` that runtime is **containerd**; the kubelet talks to it over a Unix socket at `/run/containerd/containerd.sock`. `dockershim` (the old Docker adapter) was removed in Kubernetes 1.24, so "Kubernetes uses Docker" has been false for years — kind's *nodes* are Docker containers, but *inside* them containerd runs your pods.

Your CLI to that runtime, on the node, is **`crictl`** — think `docker ps` but for the CRI, pod-aware, and the ground truth when `kubectl` is lying or unavailable.

```bash
# crictl talks to the node's CRI socket. Run it inside the node container:
docker exec dojo-worker crictl ps                 # running containers (app containers)
docker exec dojo-worker crictl pods               # pod SANDBOXES (one per pod, see below)
docker exec dojo-worker crictl images             # images cached on THIS node
docker exec dojo-worker crictl inspect <container-id>   # full runtime view: mounts, env, cgroup, netns
docker exec dojo-worker crictl logs <container-id>      # container stdout/stderr at the runtime level
```

| You know (kubectl) | The runtime calls it (crictl) |
|--------------------|-------------------------------|
| `kubectl get pods` | `crictl pods` (sandboxes) + `crictl ps` (containers) |
| `kubectl logs` | `crictl logs <id>` |
| `kubectl exec` | `crictl exec -it <id> sh` |
| image pull | containerd pulls; `crictl images` lists the cache |

**Why go to `crictl` at all?** Because when the api-server is down (Module 01) or a pod is wedged in `ContainerCreating`, `kubectl` can't help — the truth is on the node, and `crictl` reads it directly from containerd.

### The pause container (the "sandbox")

Every pod has a hidden extra container you never wrote: the **pause** container. The kubelet creates it *first*, and it owns the pod's network and IPC namespaces. Your app containers then **join** the pause container's namespaces — which is *why* all containers in a pod share one IP and can reach each other on `localhost`.

```bash
docker exec dojo-worker crictl ps -a | grep pause        # one pause per pod (may show as the sandbox)
docker exec dojo-worker crictl pods                       # each "POD" here IS a pause/sandbox
```

The pause container does nothing but sleep and reap zombies. It exists purely to be the stable holder of the network namespace, so individual app containers can crash and restart without the pod losing its IP. Kill the pause container and the *whole pod* is torn down and recreated.

---

## The CNI: how a pod gets an IP

When the kubelet creates a pod sandbox, it calls a **CNI plugin** to set up networking. The CNI contract is dead simple: *"here's a network namespace, give it connectivity and return an IP."* The plugin creates a `veth` pair (one end in the pod's netns, one end on the node), plugs the node end into a bridge or overlay, assigns an IP from the node's pod CIDR, and writes routes.

The Kubernetes network model the CNI must satisfy has three flat rules — **no NAT between pods**:

1. Every pod gets its own IP.
2. Every pod can reach every other pod on any node **without NAT**.
3. Agents on a node (kubelet) can reach all pods on that node.

```
┌──────────────── dojo-worker (a node) ─────────────────┐     ┌──────── dojo-worker2 ────────┐
│                                                        │     │                              │
│  ┌─ pod netns ─┐   ┌─ pod netns ─┐                     │     │   ┌─ pod netns ─┐            │
│  │ eth0        │   │ eth0        │                     │     │   │ eth0        │            │
│  │ 10.244.1.5  │   │ 10.244.1.6  │                     │     │   │ 10.244.2.4  │            │
│  └─────┬───────┘   └─────┬───────┘                     │     │   └─────┬───────┘            │
│      veth│             veth│                           │     │       veth│                  │
│     ┌────┴─────────────────┴────┐                      │     │     ┌─────┴──────┐           │
│     │   cni0 bridge (10.244.1.1)│                       │     │     │  cni0      │           │
│     └────────────┬──────────────┘                      │     │     └─────┬──────┘           │
│                  │ node routes / overlay               │     │           │                 │
│              eth0│ 172.18.0.x  ◀───── pod-to-pod, no NAT ────▶ eth0 172.18.0.y              │
└──────────────────┴─────────────────────────────────────┘     └───────────────────────────-─┘
       pod CIDR per node (e.g. 10.244.1.0/24, 10.244.2.0/24) carved from the cluster CIDR 10.244.0.0/16
```

### kindnet vs Calico — and who enforces NetworkPolicy

`kind`'s default CNI is **kindnet**: a minimal plugin that assigns pod CIDRs per node and adds plain routes between nodes (kind nodes share a Docker bridge, so no real overlay/encapsulation is needed). It is deliberately bare-bones — crucially, **kindnet does not enforce `NetworkPolicy`.** You can `kubectl apply` a NetworkPolicy on default kind and it will be silently ignored, because nothing is programming the rules.

| | **kindnet** (kind default) | **Calico** |
|---|---|---|
| Pod IPAM + routing | Yes (simple host routes) | Yes (BGP or VXLAN) |
| NetworkPolicy enforcement | **No** — policies are inert | **Yes** — programs iptables/eBPF to drop disallowed traffic |
| Use when | Learning plumbing, Services, DNS | You need to *test that a NetworkPolicy actually blocks traffic* |

The operational trap: you write a `default-deny` NetworkPolicy, test on vanilla kind, see traffic still flowing, and conclude your policy is broken. It isn't — **there's just no enforcer.** To exercise NetworkPolicy in the dojo you install Calico (it replaces kindnet as the CNI). NetworkPolicy is **namespaced and additive**: with no policy selecting a pod, all traffic is allowed; the first policy that selects a pod flips it to default-deny for the directions (ingress/egress) that policy specifies, and rules are a *union* across all policies selecting that pod.

---

## Inside the pod's network namespace

The pod's IP, interfaces, and routes live in a Linux network namespace owned by the pause container. You can enter it from the node and see exactly what the pod sees — this is the single most clarifying thing in cluster networking.

```bash
# From a debug pod: netshoot gives you ip/ss/dig/tcpdump inside the pod network
kubectl -n dojo-net run netshoot --rm -it --image=nicolaka/netshoot -- bash
#   inside:  ip addr          # eth0 with the pod IP + a veth peer index
#            ip route         # default via the cni0 bridge gateway
#            cat /etc/resolv.conf   # nameserver = the kube-dns/CoreDNS Service ClusterIP
#            dig web.dojo-net.svc.cluster.local   # Service DNS resolution

# From the NODE: find a container's netns and poke it with nsenter
PID=$(docker exec dojo-worker crictl inspect <container-id> \
        -o jsonpath='{.info.pid}' 2>/dev/null)
docker exec dojo-worker sh -c "nsenter -t $PID -n ip addr"      # the pod's interfaces
docker exec dojo-worker sh -c "nsenter -t $PID -n ip route"     # the pod's routing table
```

`/etc/resolv.conf` in every pod points at CoreDNS's **ClusterIP Service** (typically `10.96.0.10`) with a `search` list (`<ns>.svc.cluster.local svc.cluster.local cluster.local`), which is why `curl web` resolves to `web.<ns>.svc.cluster.local` — the search-domain magic, not DNS wildcards.

---

## How a Service VIP maps to real pods

A Service's `ClusterIP` is a **virtual IP that nothing actually listens on.** No process binds it. It's a load-balancing fiction maintained by **kube-proxy**, which watches EndpointSlices (the Ready pod IPs behind a Service) and programs the node's **iptables** (default) or **IPVS** so that packets *to the VIP* get DNAT'd to one of the real pod IPs.

```
curl 10.96.42.10:80  (the Service ClusterIP — no one listens here)
        │
        ▼  kube-proxy's iptables rules on the node:
   KUBE-SERVICES ──▶ KUBE-SVC-xxxx ──(random/round-robin probability)──▶ KUBE-SEP-aaaa  DNAT ▶ 10.244.1.5:80
                                                                    └──▶ KUBE-SEP-bbbb  DNAT ▶ 10.244.2.4:80
        │
        ▼  reply traffic un-DNATs on the way back — the client only ever saw the VIP
```

So the chain end to end is: **DNS (CoreDNS) resolves the Service name → ClusterIP → kube-proxy iptables DNAT → a real pod IP (routed there by the CNI).** Every layer in this module shows up in that one `curl`.

```bash
# The Service VIP and its backing endpoints
kubectl -n dojo-net get svc web -o jsonpath='{.spec.clusterIP}{"\n"}'
kubectl -n dojo-net get endpointslices -l kubernetes.io/service-name=web \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}'

# The actual DNAT rules kube-proxy wrote (on the node)
docker exec dojo-worker sh -c 'iptables-save -t nat | grep -E "KUBE-SVC|KUBE-SEP" | head'
```

A Service with **no Ready pods** has an **empty EndpointSlice** → kube-proxy writes a `REJECT`/no-backend rule → `curl` to the VIP gives `connection refused`. That's not DNS and not CNI; it's "your selector matches nothing Ready."

---

## Debugging pods stuck in ContainerCreating / network failures

`ContainerCreating` means the pod is **bound and the kubelet is working on it** — the scheduler is done (Module 02). The kubelet is stuck somewhere in: pull image → create sandbox → **call CNI** → start containers. CNI failure is the classic reason a pod sits in `ContainerCreating` for minutes.

| Symptom | Likely cause | Diagnose with | Fix |
|---------|--------------|---------------|-----|
| `ContainerCreating` for minutes; Events show `failed to setup network for sandbox` / `plugin not initialized` | CNI plugin not ready / crashed (kindnet or Calico pod down) | `kubectl -n kube-system get pods \| grep -E 'kindnet\|calico'` | Restart the CNI DaemonSet pod on that node |
| `ContainerCreating`; Events show `failed to allocate IP` / `no IP addresses available in range` | Node's pod CIDR exhausted (IPAM out of IPs) | `crictl pods` count vs the `/24` CIDR size | Reduce pod density, enlarge pod CIDR, or clean leaked sandboxes |
| `ImagePullBackOff` / `ErrImagePull` (NOT a network-fabric issue) | Image tag typo, private registry, or node can't reach registry | `kubectl describe pod` Events; `crictl pull <image>` on the node | Fix tag/creds; for local images `kind load docker-image <img>` |
| Pod `Running` but `curl <service>` → `could not resolve host` | DNS broken (CoreDNS down or wrong `resolv.conf`) | `kubectl -n kube-system get pods -l k8s-app=kube-dns`; from netshoot `cat /etc/resolv.conf && dig <svc>` | Restart CoreDNS; verify the kube-dns Service ClusterIP |
| Pod `Running` but `curl <service-VIP>` → `connection refused` | Service has **no Ready endpoints** (selector mismatch or probes failing) | `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` | Fix the selector/labels, or get pods passing readiness |
| Pod-to-pod across nodes fails; same-node works | CNI inter-node routing/overlay broken | `nsenter … ip route` in the pod; `kubectl get nodes -o wide` for podCIDRs | Check the CNI DaemonSet logs on both nodes |
| NetworkPolicy "not blocking" traffic | kindnet doesn't enforce policy — no enforcer installed | `kubectl -n kube-system get ds` (is Calico present?) | Install Calico to actually enforce NetworkPolicy |

The commands, in order, for a stuck `ContainerCreating`:

```bash
# 1. The verdict — kubelet/CNI errors land in the pod's Events
kubectl -n <ns> describe pod <pod> | sed -n '/Events:/,$p'

# 2. Which node is it on, and is the CNI healthy there?
NODE=$(kubectl -n <ns> get pod <pod> -o jsonpath='{.spec.nodeName}')
kubectl -n kube-system get pods -o wide | grep -E "kindnet|calico" | grep "$NODE"

# 3. Drop to the node: is the sandbox even created? what did the CNI say?
docker exec "$NODE" crictl pods | grep <pod-name-prefix>
docker exec "$NODE" journalctl -u kubelet --no-pager | grep -iE 'cni|network|sandbox' | tail -30

# 4. Image problems: pull it manually on the node to see the real error
docker exec "$NODE" crictl pull nginx:1.27-alpine

# 5. Inspect the sandbox's assigned IP (or lack thereof) and its netns
docker exec "$NODE" crictl inspectp <sandbox-id> | grep -iE 'ip|state'
```

> **War story.** A new worker node joined a cluster and every pod scheduled onto it hung in `ContainerCreating`. `kubectl describe pod` repeated `failed to setup network for sandbox: plugin type="calico" failed (add): connection refused`. The pods on the *old* nodes were all fine, which sent the team chasing a "bad node" theory for an hour — reimaging, checking kernel versions, the works. The actual cause: the Calico DaemonSet pod on the new node was itself `CrashLoopBackOff` because the node's `--pod-cidr` hadn't been allocated by the controller-manager (a misconfigured `--allocate-node-cidrs`). No CNI agent → no IPAM → the kubelet's CNI `ADD` call had nothing to answer it → every pod stuck at the network-setup step. The tell was in step 2 above: `kubectl -n kube-system get pods -o wide | grep calico` showed the agent on that one node crashlooping while all others were `Running`. The lesson: **`ContainerCreating` is the kubelet waiting on the CNI, and the CNI is just another pod that can be down.** Always check the CNI DaemonSet on the *specific node* before blaming the node itself.

> **War story, the DNS one.** A service worked by pod IP but `curl http://payments` returned `could not resolve host` — intermittently, which is the worst kind. From a `netshoot` pod, `cat /etc/resolv.conf` was correct and `dig payments.prod.svc.cluster.local @10.96.0.10` worked *sometimes*. The cause: two CoreDNS replicas, one of them wedged (OOM-killed, stuck `Running` but not answering), and kube-proxy was load-balancing the kube-dns Service VIP across both — so half of all DNS queries hit a dead resolver and timed out. `kubectl -n kube-system get pods -l k8s-app=kube-dns` showed `2/2 Running` which *looked* fine; `kubectl -n kube-system get endpointslices` + hitting each CoreDNS pod IP directly with `dig` exposed the dead one. Bumping CoreDNS memory and adding a readiness probe that actually fails on a dead resolver fixed it. The lesson: **a Service VIP faithfully load-balances to a dead endpoint if that endpoint still reports Ready** — intermittent failures across a VIP almost always mean one bad backend, and you find it by testing pod IPs individually, bypassing the VIP.

---

## Checkpoint

You've got this module when you can, without looking it up:

1. Explain the split between CRI and CNI — the kubelet speaks CRI gRPC to containerd to run containers, and calls a CNI plugin to give the sandbox an IP.
2. Use `crictl` on a node (`pods`, `ps`, `logs`, `inspect`) and say why you'd reach for it instead of `kubectl`.
3. Explain the pause/sandbox container's role and why it's *why* all containers in a pod share one IP and `localhost`.
4. State the three CNI network-model rules (pod IP, no-NAT pod-to-pod, node reaches pods) and explain why kindnet ignores NetworkPolicy while Calico enforces it.
5. Enter a pod's network namespace via `nsenter` from the node and read its `ip addr`/`ip route`/`resolv.conf`.
6. Trace a `curl <service>` end to end: CoreDNS resolves the name → ClusterIP VIP → kube-proxy iptables DNAT → a real pod IP routed by the CNI — and say which layer a `could not resolve host` vs a `connection refused` points to.
7. Triage `ContainerCreating` as a kubelet/CNI problem (never a scheduler problem), checking the CNI DaemonSet on the specific node first.

➡ That closes the internals arc: control plane (who decides) → scheduler (where it runs) → CRI/CNI (how it actually runs and connects). From here the course moves into the operator's seat — etcd backup/restore, kubeadm upgrades, and repository management.
