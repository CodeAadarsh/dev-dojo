# CNI & the Pod Network

> **Module 01 · Course 07** — Pods communicate as if they're on a flat L3 network: no NAT between pods on the same node, no NAT between pods on different nodes. That model doesn't happen by magic; a CNI plugin wires it, and understanding *how* is what lets you debug anything from a stuck `ContainerCreating` to silent packet drops under high load.

You know what a pod is. This module covers how it gets an IP, why the CNI binary matters more than the CNI daemon, what the overlay/routed tradeoff costs you, and how to reach inside a pod's network namespace from the host when the pod has no shell.

---

## How a pod gets its IP

When the kubelet decides to start a pod it calls the container runtime (containerd), which calls the **CNI plugin** to wire up networking. The sequence is synchronous and blocking — the container runtime will not return "pod started" to the kubelet until CNI exits with a success JSON payload:

```
kubelet
  └─ containerd (CRI: RunPodSandbox)
       └─ CNI binary  /opt/cni/bin/<plugin>
            ├─ creates a veth pair
            │    eth0     →  inside the new pod netns
            │    vethXXX  →  on the node's root netns, attached to bridge or routed
            ├─ assigns an IP from the pod CIDR slice for this node
            ├─ sets the default route inside the pod
            └─ returns JSON { "ip": "10.244.1.5/24", "gateway": "10.244.1.1" }
```

The kubelet writes that IP to `.status.podIP`. Until CNI exits 0, the pod is stuck at `ContainerCreating` — there is no retry loop, no timeout extension, just the kernel blocking on the binary's exit.

**IP allocation model.** The cluster allocates a /16 pod CIDR at creation time (`--cluster-cidr`). The controller-manager slices it per node with `--node-cidr-mask-size` (default `/24`):

```
cluster pod CIDR  10.244.0.0/16
  dojo-control-plane  10.244.0.0/24   (≤254 pods)
  dojo-worker         10.244.1.0/24
  dojo-worker2        10.244.2.0/24
```

Inspect what a node was assigned:

```bash
kubectl get node dojo-worker -o jsonpath='{.spec.podCIDR}{"\n"}'
# -> 10.244.1.0/24

# see all pod IPs in the cluster and which node they landed on
kubectl get pods -A -o wide --no-headers | awk '{print $8, $7}' | sort -V
```

If you fill all 254 slots per node, new pods stay `Pending` with `FailedScheduling: 0/3 nodes are available: 3 node(s) didn't have free IP available`. The mask size is set at cluster creation; changing it requires a kube-controller-manager restart and is not live-patchable on existing nodes.

---

## The CNI spec

CNI is a **spec + calling convention**, not a daemon. A CNI plugin is a binary that:

1. Is called with the operation (`ADD` / `DEL` / `CHECK`) in the env var `CNI_COMMAND`.
2. Reads its config from stdin (or a `.conflist` in `/etc/cni/net.d/`).
3. Does kernel work (veth, IP, routes, iptables) and exits 0 with JSON on success, or non-zero with an error JSON on failure.

There is no long-running CNI process on the data path. After `ADD` completes, the kernel carries packets for that pod with zero CNI involvement. This means CNI bugs are initialization bugs, not runtime bugs — if the pod is Running and talking, CNI is done.

```bash
# inspect the CNI config that kindnet wrote
docker exec dojo-control-plane ls /etc/cni/net.d/
docker exec dojo-control-plane cat /etc/cni/net.d/10-kindnet.conflist
```

Multiple plugins can be **chained** via a `.conflist` (the `plugins` array). kindnet chains:

| Plugin | Role |
|---|---|
| `ptp` | Creates the veth pair, sets up routes |
| `host-local` | Allocates the IP from the per-node CIDR range |
| `portmap` | Manages `hostPort` iptables rules |

The runtime calls each plugin in order with the output of the previous one. If `host-local` fails (CIDR exhausted), `ptp` already ran — the runtime will call `DEL` on `ptp` to clean up the veth, which is why partial-failure cleanup matters.

---

## kindnet vs Calico vs Cilium

| Feature | kindnet | Calico | Cilium |
|---|---|---|---|
| Data plane | iptables, host-gw or VXLAN | iptables or eBPF, VXLAN or BGP | eBPF (bypasses netfilter entirely) |
| NetworkPolicy enforcement | **None** | Yes — K8s NP + GlobalNetworkPolicy | Yes — K8s NP + CiliumNetworkPolicy |
| Performance | Fine for dojo scale | Good; BGP mode is near-wire | Best; eBPF skips conntrack for most traffic |
| kind support | Ships by default (no config needed) | `disableDefaultCNI: true` + install | Same |
| Observability | None | Flow logs via `calicoctl` | Hubble UI — L7-aware full connection graph |

**For this course:** modules 01–03 work with the default kindnet cluster. The NetworkPolicy module (04) requires a Calico-enabled cluster — the install prereq will be stated in each challenge's `brief.md`.

```bash
# which CNI is active?
kubectl -n kube-system get pods -o wide | grep -E 'kindnet|calico|cilium'

# kindnet's ConfigMap holds its tunable settings (MTU, masquerade rules)
kubectl -n kube-system get cm kindnet-cfg -o yaml 2>/dev/null || \
  kubectl -n kube-system describe ds kindnet | grep -A5 Containers
```

---

## Overlay vs routed networking

These are the two fundamental models for how a packet from pod-a (node-1) reaches pod-b (node-2).

### Overlay (VXLAN)

Pod packets are encapsulated in an outer UDP packet before crossing the node boundary. The outer IP is the node's real NIC IP; the inner IP is the pod IP. The receiving node's VTEP (Virtual Tunnel End Point) strips the outer header.

```
┌─ node-1 ────────────────────────────────────────────────────────────┐
│  pod-a (10.244.1.5)  →  veth  →  bridge  →  VTEP                   │
│                                               │                      │
│  outer: 172.18.0.3:4789 → 172.18.0.4:4789   │  (VXLAN UDP)        │
│  inner: 10.244.1.5 → 10.244.2.7              │                      │
└───────────────────────────────────────────────┼──────────────────────┘
                                                │
┌─ node-2 ──────────────────────────────────────┼──────────────────────┐
│  VTEP decap  →  bridge  →  veth  →  pod-b (10.244.2.7)              │
└──────────────────────────────────────────────────────────────────────┘
```

Works across any IP network, including across different subnets and cloud availability zones. The cost: 50 bytes of VXLAN header on every pod packet, which reduces effective MTU.

### Routed (BGP / host-gw)

No encapsulation. Each node advertises its pod CIDR to its neighbors via BGP (Calico) or by writing kernel routes directly (kindnet host-gw mode when nodes are on the same L2 segment). The node's routing table has:

```
10.244.2.0/24 via 172.18.0.4 dev eth0
```

A packet from pod-a to pod-b is forwarded as a plain IP packet — no wrap, no unwrap. Near-wire performance. The constraint: nodes must be L2 adjacent (same subnet) for host-gw mode, or you need a BGP peer for cross-subnet routing.

**kind uses host-gw** when all nodes are on the same Docker bridge (which they are). If you add VXLAN on top (e.g., Calico in VXLAN mode), you get a double encap — see MTU.

---

## The pod network namespace

Every pod runs in its own network namespace: its own `eth0`, its own routing table, its own `iptables` chain set. The host has a corresponding `vethXXX` in the root netns, bridged to the CNI bridge or directly routed.

```bash
# find the veth peer index from inside the pod
kubectl exec -n <ns> <pod> -- ip link show eth0
# -> 4: eth0@if9: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...
# if-index 9 is the HOST side of the pair

# on the node, find interface index 9
docker exec dojo-worker ip link | grep '^9:'
# -> 9: vethXXX@if4 ...
```

For pods without shell or networking tools (`distroless`, `scratch`), reach inside from the host using `crictl` and `nsenter`:

```bash
# 1. find the container ID of the pod's pause container
docker exec dojo-worker crictl pods --name <pod-name> -q
POD_ID=<output>

# 2. get the netns path
docker exec dojo-worker crictl inspectp "$POD_ID" | grep -i '"path"' | grep netns
# -> "path": "/var/run/netns/cni-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# 3. run commands inside the pod's netns from the host
docker exec dojo-worker nsenter --net=/var/run/netns/cni-XXXX ip addr
docker exec dojo-worker nsenter --net=/var/run/netns/cni-XXXX ip route
docker exec dojo-worker nsenter --net=/var/run/netns/cni-XXXX ss -tnp
```

This technique works for live debugging of pods in production where you have node access but the pod has no tooling. You get the full network view — routes, sockets, iptables — without modifying the pod.

---

## MTU gotchas

MTU mismatches are silent and asymmetric: small packets work; large packets are silently dropped (if the DF bit is set) or fragmented. The observable symptom is large-payload requests timing out while small ones (health checks, DNS) succeed.

| Stack | MTU calculation | Effective pod MTU |
|---|---|---|
| kindnet host-gw (no encap) | Node NIC MTU (1500) | **1500** |
| kindnet VXLAN | 1500 − 50-byte VXLAN | **1450** |
| Calico BGP (no encap) | Node NIC MTU | **1500** |
| Calico VXLAN | 1500 − 50 | **1450** |
| kind (Docker bridge 1500) + Calico VXLAN | 1500 − 50 (Docker NAT) − 50 (VXLAN) | **~1400** |

Docker Desktop on Mac runs nodes inside a Linux VM bridged at 1500 bytes — the VXLAN tunnel sits on top of that bridge. Nested virtualization isn't adding extra encap here, but if you run kind inside a cloud VM that itself uses VXLAN (common in GKE/EKS node-level networking), you can end up with a 1350-byte effective MTU.

```bash
# check the MTU inside a running pod
kubectl run mtu-check --rm -it --image=nicolaka/netshoot:v0.13 -- ip link show eth0
# -> mtu 1450 (or whatever your CNI configured)

# what MTU did kindnet choose?
kubectl -n kube-system get ds kindnet -o jsonpath='{.spec.template.spec.containers[0].env}' \
  | tr ',' '\n' | grep -i mtu

# test whether a specific large packet gets through (PMTUD probe)
kubectl run mtu-test --rm -it --image=nicolaka/netshoot:v0.13 -- \
  ping -M do -s 1400 10.244.2.1   # -M do = set DF bit; -s = payload bytes
# if you get "Frag needed" or no reply → MTU problem
```

A real-world symptom: gRPC and HTTP/2 connections work for small requests but hang or reset on large response bodies. Both protocols keep a connection alive and send large frames when throughput is high — exactly the packet sizes that exceed a misconfigured MTU.

---

## Debugging CNI

Diagnose in this order: get the pod's node → check CNI logs on that node → check the CNI binary and config → verify kernel state.

| Symptom | Likely cause | Fix |
|---|---|---|
| `ContainerCreating`, event: `networkPlugin cni failed to set up pod` | CNI binary crashed or not found | Check `/opt/cni/bin/` on the node; restart CNI DaemonSet |
| `ContainerCreating`, event: `failed to allocate for range 0: no IP addresses available` | Node pod CIDR exhausted (>254 pods) | Scale node pool; lower `--node-cidr-mask-size` at cluster creation |
| Pod Running, can't reach pods on the same node | veth not bridged, or iptables FORWARD DROP | `ip link` + `bridge fdb` on node; check `iptables -L FORWARD -n` |
| Pod Running, reaches same-node pods, fails cross-node | VXLAN port blocked (UDP 4789) or kernel route missing | Test with `ping` between node IPs; check `ip route` on sending node |
| MTU-sized payloads time out, small ones work | MTU mismatch (double encap or wrong CNI config) | Measure MTU inside pod; compare with encap stack overhead |
| All pods `CrashLoopBackOff` after swapping CNI | Stale netns state from old CNI | Drain node, delete pods, restart containerd |

### The exact commands

**Pod stuck `ContainerCreating`:**

```bash
# which node?
kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.nodeName}{"\n"}'

# read the events (most specific signal)
kubectl describe pod <pod> -n <ns> | tail -20

# containerd logs on the node often have the CNI error with more detail
docker exec dojo-worker journalctl -u containerd --no-pager --since "5 minutes ago" | tail -40

# is the CNI binary present?
docker exec dojo-worker ls -la /opt/cni/bin/
# is the CNI config valid JSON?
docker exec dojo-worker cat /etc/cni/net.d/10-kindnet.conflist | python3 -m json.tool
```

**No pod-to-pod connectivity:**

```bash
# pin two pods to different nodes for the test
kubectl run pod-a --image=nicolaka/netshoot:v0.13 \
  --overrides='{"spec":{"nodeName":"dojo-worker"}}' -- sleep 3600
kubectl run pod-b --image=nicolaka/netshoot:v0.13 \
  --overrides='{"spec":{"nodeName":"dojo-worker2"}}' -- sleep 3600

POD_B_IP=$(kubectl get pod pod-b -o jsonpath='{.status.podIP}')
kubectl exec pod-a -- ping -c3 "$POD_B_IP"

# if ping fails, look at FORWARD chain on the sending node
docker exec dojo-worker iptables -L FORWARD -n -v | head -30

# is the VXLAN/route in place?
docker exec dojo-worker ip route show | grep 10.244
docker exec dojo-worker ip -d link show | grep -i vxlan
```

**crictl + nsenter for a shellless pod:**

```bash
# get the pod sandbox ID
POD_ID=$(docker exec dojo-worker crictl pods \
  --namespace <ns> --name <pod-name> -q)

# get the netns path
NS_PATH=$(docker exec dojo-worker sh -c \
  "crictl inspectp $POD_ID" | grep '"path"' | grep netns | awk -F'"' '{print $4}')

echo "netns: $NS_PATH"
docker exec dojo-worker nsenter --net="$NS_PATH" ip addr
docker exec dojo-worker nsenter --net="$NS_PATH" ip route
docker exec dojo-worker nsenter --net="$NS_PATH" ss -tnp
```

> **War story.** During a Calico migration at SAP, new pods on migrated nodes came up `Running` with correct IPs but couldn't reach kube-apiserver — `kubectl exec` hung, health checks timed out, but the pod looked fine. Root cause: the node had a legacy iptables hardening job that set `iptables -P FORWARD DROP` as a security baseline, and Calico's rule insertion for the new node landed *after* the DROP — meaning the ACCEPT rules existed but were unreachable. The symptom was a healthy pod with a silent kernel blackhole. Fix: `iptables -P FORWARD ACCEPT` on each affected node while Calico finished BGP sync, then confirmed with `calicoctl node status`. The lesson: iptables is an ordered list, and a CNI assumes it is the primary author of the FORWARD chain. External hardening that sets a default DROP policy will win over late-inserted ACCEPT rules until you audit the chain ordering.

---

## Checkpoint

You're ready for the CNI challenges when you can, without looking anything up:

1. Name the four things the CNI binary does during `ADD` and where the assigned IP appears in the Kubernetes API.
2. Explain why a pod stays `ContainerCreating` when CNI fails — what is actually blocking, and where does the error appear?
3. Calculate the effective pod MTU for a kind cluster running Calico in VXLAN mode on a Docker Desktop bridge, and state why the number is lower than 1500.
4. Find the network namespace path for a running pod using `crictl inspectp`, then run `ip route` inside it from the host without entering the pod.
5. Diagnose a pod stuck `ContainerCreating` end-to-end: which node, which log, which binary/config file to check.
6. Launch two pods pinned to specific nodes and verify cross-node ICMP connectivity; if it fails, name the two kernel structures to inspect first.
7. Explain the difference between overlay (VXLAN) and routed (host-gw/BGP) modes: when each requires the other approach and what the performance tradeoff is.

➡ Next: **Services, kube-proxy & DNS** — how a ClusterIP VIP becomes real pod IPs via iptables DNAT chains, why EndpointSlice readiness beats pod phase, and what `ndots:5` does to your external DNS latency.
