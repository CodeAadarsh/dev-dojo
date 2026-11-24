# Solution: Custom Bridge Isolation

## Why containers on the same network can talk

Every Docker network creates a Linux **bridge interface** (like `br-a1b2c3d4`) on the host. Containers connected to that network get a **veth pair**: one end is the container's `eth0`, the other end is attached to the bridge. The kernel routes packets between veth endpoints via the bridge — no iptables required, it's L2 switching.

Containers on **different** bridges are isolated because:

1. They are on different subnets (e.g., `172.19.0.0/16` vs `172.20.0.0/16`)
2. Docker inserts iptables rules in the `DOCKER-ISOLATION-STAGE-1` and `DOCKER-ISOLATION-STAGE-2` chains that explicitly DROP traffic between bridge interfaces

## Confirm the problem first

```bash
docker exec dojo-payments ping -c 2 dojo-internal-api
# PING dojo-internal-api (172.19.0.3): 56 data bytes
# 64 bytes from 172.19.0.3: seq=0 ttl=64 time=0.1 ms
# — They can talk. This is the security issue.
```

## Fix: create an isolated network and move dojo-internal-api

```bash
# Step 1: Create the isolated network
docker network create --driver bridge dojo-isolated

# Step 2: Disconnect dojo-internal-api from the shared network
docker network disconnect dojo-shared dojo-internal-api

# Step 3: Connect it to the isolated network
docker network connect dojo-isolated dojo-internal-api

# Step 4: Prove isolation
docker exec dojo-payments ping -c 2 dojo-internal-api
# ping: bad address 'dojo-internal-api'
# — dojo-payments cannot resolve the name because they are on different networks.
```

## Why name resolution also breaks

Docker's embedded DNS (`127.0.0.11` inside each container) resolves container names **only within the same network**. When `dojo-payments` asks for `dojo-internal-api`, Docker's DNS checks which containers are on the same network as `dojo-payments` (`dojo-shared`). Since `dojo-internal-api` is no longer on `dojo-shared`, the DNS lookup returns nothing.

## Update the proof ConfigMap

```bash
kubectl patch configmap network-proof -n dojo-docker-bridge \
  -p '{"data":{"isolated_network":"dojo-isolated"}}'
```

## Inspect the iptables rules Docker creates

```bash
# See Docker's isolation chains
sudo iptables -L DOCKER-ISOLATION-STAGE-1 -n
# Chain DOCKER-ISOLATION-STAGE-1
# DOCKER-ISOLATION-STAGE-2  all  --  0.0.0.0/0  0.0.0.0/0  in: br-aaa
# DOCKER-ISOLATION-STAGE-2  all  --  0.0.0.0/0  0.0.0.0/0  in: br-bbb
# RETURN all -- 0.0.0.0/0 0.0.0.0/0

sudo iptables -L DOCKER-ISOLATION-STAGE-2 -n
# DROP all -- 0.0.0.0/0 0.0.0.0/0  out: br-bbb
# DROP all -- 0.0.0.0/0 0.0.0.0/0  out: br-aaa
# RETURN all -- 0.0.0.0/0 0.0.0.0/0
```

Stage 1 catches packets coming from bridge A, stage 2 drops them if they're going to bridge B. This is what makes Docker networks isolated by default.

## Kubernetes equivalent

In Kubernetes, the equivalent isolation mechanism is **NetworkPolicy**. A `NetworkPolicy` controls which pods can communicate using label selectors — it doesn't require separate subnets. Calico, Cilium, and Weave implement NetworkPolicies by programming iptables or eBPF rules at the node level.
