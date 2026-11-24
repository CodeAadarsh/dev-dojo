# Docker Networking — Packets and Plumbing

> **Module 07 · Course 37** — When your container pings google.com, what actually happens? The packet doesn't just teleport — it goes through a virtual Ethernet cable, a Linux bridge, an iptables NAT rule, and your physical NIC. This module traces every hop, shows you the iptables rules Docker injects, and explains why containers on different custom networks can't talk to each other.

---

## Network Drivers

Docker supports several network drivers. Each creates a different topology:

| Driver | What it creates | Use case |
|--------|----------------|---------|
| **bridge** (default) | A virtual switch + veth pairs | Standard container isolation |
| **host** | No network namespace — uses host's network | High performance, debugging |
| **none** | Loopback only | Fully isolated, no networking |
| **overlay** | Multi-host networking (via VXLAN) | Docker Swarm, Kubernetes (sort of) |
| **macvlan** | Each container gets a real MAC + IP on the physical network | Legacy systems needing direct LAN access |

```bash
# See available drivers
docker network ls
# NETWORK ID     NAME      DRIVER    SCOPE
# abc123         bridge    bridge    local
# def456         host      host      local
# ghi789         none      null      local

# Default: bridge network named "bridge"
docker network inspect bridge --format '{{json .IPAM.Config}}'
# [{"Subnet":"172.17.0.0/16","Gateway":"172.17.0.1"}]
```

---

## The Linux Bridge (docker0)

When Docker starts, it creates a Linux bridge called `docker0`. Think of it as a **virtual switch** — it connects multiple network interfaces at Layer 2 (Ethernet).

```bash
# See docker0 on the host
ip addr show docker0
# 3: docker0: <BROADCAST,MULTICAST,UP,LOWER_UP>
#     inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0

# docker0 is a standard Linux bridge
brctl show docker0  # (if bridge-utils installed)
# bridge name    bridge id         STP enabled  interfaces
# docker0        8000.0242ab12cd34  no          veth123abc
#                                               veth456def
```

Each container connected to the bridge has one entry in the `interfaces` column — that's the host end of its veth pair.

---

## veth Pairs: Virtual Ethernet Cables

Every time Docker starts a container on the bridge network, it creates a **veth pair** — two connected virtual network interfaces. Think of it as a pipe: bytes into one end come out the other.

```
container network namespace         host network namespace
───────────────────────────         ──────────────────────
eth0 (172.17.0.2)         ◄──────► veth123abc
                          veth pair  │
                                     └── attached to docker0 bridge
```

```bash
# Start a container
docker run -d --name veth-demo nginx:1.27-alpine

# Find the veth pair on the host
docker inspect veth-demo --format '{{.NetworkSettings.SandboxKey}}'
# /var/run/docker/netns/abc123def456

# List veth interfaces on the host
ip link | grep veth
# 5: veth123abc@if4: <BROADCAST,MULTICAST,UP,LOWER_UP>

# The number after @if is the interface index INSIDE the container
# Check it:
CPID=$(docker inspect veth-demo --format '{{.State.Pid}}')
sudo nsenter -t $CPID --net ip link
# 1: lo: ...
# 4: eth0@if5: ...    ← @if5 means it's the pair of host's veth (index 5)

docker rm -f veth-demo
```

---

## Packet Journey: Container to Internet

Here's every hop a packet takes from a container to the internet:

```
Container (172.17.0.2)
    │   eth0 — sends packet to gateway (172.17.0.1)
    │
    ▼  veth pair (virtual cable through the kernel)
veth123abc  (host end of the pair, attached to docker0)
    │
    ▼
docker0 bridge  (172.17.0.1 — the gateway the container uses)
    │
    ▼  kernel routing: 0.0.0.0/0 → host's default route
    │
    ▼  iptables POSTROUTING chain (nat table)
    │  MASQUERADE rule: rewrite source IP 172.17.0.2 → host IP 192.168.1.5
    │
    ▼
eth0 / en0  (host physical NIC — 192.168.1.5)
    │
    ▼
internet (sees packet from 192.168.1.5, not 172.17.0.2)
```

**MASQUERADE** is source NAT — the host rewrites the container's private IP to its own public IP before sending. The kernel tracks the connection so it can rewrite incoming replies back.

---

## Port Publishing: Incoming Packets

When you do `docker run -p 8080:80`, Docker adds a DNAT rule:

```
Client (1.2.3.4) → host:8080
    │
    ▼  iptables PREROUTING chain (nat table)
    │  DNAT rule: destination 0.0.0.0:8080 → 172.17.0.2:80
    │
    ▼
Container eth0 (172.17.0.2:80)
```

```bash
# Start a container with port mapping
docker run -d -p 8080:80 --name port-demo nginx:1.27-alpine

# See the DNAT rule Docker created
sudo iptables -t nat -L DOCKER --line-numbers
# Chain DOCKER (2 references)
# num  target     prot opt source    destination
# 1    RETURN     all  --  anywhere  anywhere   ADDRTYPE match dst-type LOCAL
# 2    DNAT       tcp  --  anywhere  anywhere   tcp dpt:8080 to:172.17.0.2:80

# See the MASQUERADE rule
sudo iptables -t nat -L POSTROUTING --line-numbers
# MASQUERADE  all  --  172.17.0.0/16  anywhere

# See the FORWARD rules that allow traffic through the bridge
sudo iptables -t filter -L DOCKER --line-numbers
# ACCEPT  tcp  --  anywhere  172.17.0.2  tcp dpt:http

docker rm -f port-demo
```

---

## DNS Inside Containers

When a container does a DNS lookup (e.g., `curl http://api-service`), who answers?

Docker runs an **embedded DNS server** at `127.0.0.11` inside every container's network namespace. This is not visible on the host — it's a service inside the network namespace.

```bash
docker run --rm nginx:1.27-alpine cat /etc/resolv.conf
# nameserver 127.0.0.11       ← Docker's embedded DNS
# options ndots:0
```

The embedded DNS:
1. Checks if the name is a container/service on the same user-defined network → resolves to container IP
2. Falls back to the host's DNS for external names

**Default bridge network limitation:** Container name resolution only works on **user-defined** networks, not the default `bridge` network.

```bash
# Default bridge: containers can't resolve each other by name
docker run -d --name app1 nginx:1.27-alpine
docker run --rm --link app1 nginx:1.27-alpine ping app1  # requires --link (deprecated)

# User-defined network: name resolution works automatically
docker network create mynet
docker run -d --name app1 --network mynet nginx:1.27-alpine
docker run --rm --network mynet nginx:1.27-alpine ping app1  # works!
docker network rm mynet
docker rm -f app1
```

---

## Custom Networks and Isolation

Custom networks create a **separate bridge** with its own subnet. Containers on different custom networks cannot communicate — they're on different bridges with no routes between them.

```bash
# Create two isolated networks
docker network create --subnet 10.10.0.0/24 net-a
docker network create --subnet 10.20.0.0/24 net-b

# Start containers on each
docker run -d --name container-a --network net-a nginx:1.27-alpine
docker run -d --name container-b --network net-b nginx:1.27-alpine

# container-a cannot reach container-b
docker exec container-a ping container-b  # fails: ping: bad address 'container-b'
docker exec container-a ping 10.20.0.2    # fails: network unreachable

# Connect container-a to both networks (now it bridges them!)
docker network connect net-b container-a
docker exec container-a ping container-b  # works now!

# Cleanup
docker rm -f container-a container-b
docker network rm net-a net-b
```

**Connecting to multiple networks** is how you create a "gateway" container: it has interfaces on two networks and can route between them (not recommended in production — use proper service mesh).

---

## docker network inspect

This command gives you everything about a network's topology:

```bash
docker network create testnet
docker run -d --name svc-a --network testnet nginx:1.27-alpine
docker run -d --name svc-b --network testnet nginx:1.27-alpine

docker network inspect testnet
# {
#   "Name": "testnet",
#   "Driver": "bridge",
#   "IPAM": { "Config": [{ "Subnet": "172.21.0.0/16", "Gateway": "172.21.0.1" }] },
#   "Containers": {
#     "<id>": { "Name": "svc-a", "IPv4Address": "172.21.0.2/16" },
#     "<id>": { "Name": "svc-b", "IPv4Address": "172.21.0.3/16" }
#   }
# }

docker rm -f svc-a svc-b && docker network rm testnet
```

---

## host Network: No Namespace

```bash
# --network host: container uses the host's network stack directly
docker run --rm --network host nginx:1.27-alpine curl http://localhost
# curl connects to whatever is listening on the HOST's localhost:80, not the container's

# The container process is in the HOST's network namespace
docker run --rm --network host ip addr
# Shows the host's real interfaces (eth0, lo, docker0, etc.)
```

Host networking is useful for:
- Performance-critical workloads (zero NAT overhead)
- Containers that need to monitor host network traffic
- Debugging network issues

Risk: the container can bind any port on the host, including ports already in use.

---

## Debugging Network Issues

```bash
# Which network is a container on?
docker inspect <container> --format '{{json .NetworkSettings.Networks}}'

# Can container A reach container B?
docker exec container-a ping container-b
docker exec container-a nc -zv container-b 80

# Is DNS working?
docker exec container-a nslookup container-b
docker exec container-a cat /etc/resolv.conf

# Are the iptables rules correct?
sudo iptables -t nat -L -n -v | grep -A5 DOCKER
sudo iptables -t filter -L DOCKER-USER -n -v

# See all Docker-managed networks and their bridges
docker network ls
ip link | grep br-   # each custom network gets a br-<id> bridge
```

---

## Checkpoint

1. What is a veth pair and what problem does it solve?
2. What is `docker0` and what Linux primitive is it?
3. Trace a packet from container IP `172.17.0.3` to `8.8.8.8` — name every hop and iptables rule.
4. What is the MASQUERADE rule and why is it necessary?
5. What DNAT rule does `docker run -p 9090:8080` create?
6. What is `127.0.0.11` and why can't you see it on the host?
7. Why does container name resolution work on user-defined networks but NOT on the default bridge?
8. Two containers are on different custom Docker networks. Can they communicate? How would you connect them?
9. What is the tradeoff of `--network host`?
10. What command shows you the IP addresses of all containers on a Docker network?

➡ Next up: **Volumes and Storage** — where data lives when containers die and why the writable layer is not the right place to store anything you care about.
