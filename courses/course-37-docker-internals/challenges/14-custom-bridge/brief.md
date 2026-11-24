# Custom Bridge Isolation

The security audit came back with a finding: `payments` and `internal-api` are on the same Docker network. Any container on that network can reach any other — by name. If `payments` is compromised, the attacker has a direct route to `internal-api` with no firewall in between.

The root cause is a Docker default: when you don't specify a network, containers land on the `bridge` network (or any shared network). Proper network isolation requires putting services that should not communicate on **separate networks with no cross-links**.

---

## How Docker network isolation works

Docker creates a Linux **bridge** interface (like `docker0` or `br-xxxxxxx`) for each network. Containers on the same bridge can reach each other — the kernel routes packets via the bridge. Containers on different bridges are isolated: there is no bridge-to-bridge route, and Docker's iptables rules block cross-network traffic by default.

```
  Network: dojo-shared               Network: dojo-isolated
  ┌────────────────────┐             ┌────────────────────┐
  │   bridge: br-aaa   │             │   bridge: br-bbb   │
  │                    │             │                    │
  │  dojo-payments  ◄──┼─────✗───────┼──► dojo-internal-api│
  │  dojo-internal-api │             │                    │
  └────────────────────┘             └────────────────────┘
  (both on same bridge = can talk)   (separated = cannot talk)
```

---

## Mission

Two containers are running on the shared `dojo-shared` network:
- `dojo-payments`
- `dojo-internal-api`

They should not be on the same network. Create an isolated network and move `dojo-internal-api` to it, so `dojo-payments` can no longer reach it.

**The verifier checks:**

1. A Docker network named `dojo-isolated` exists
2. ConfigMap `network-proof` in `dojo-docker-bridge` has `data.isolated_network: dojo-isolated`

> Prove isolation by trying `docker exec dojo-payments ping -c 1 dojo-internal-api` after the fix — it should time out or fail.

Run the verifier:

```bash
bash courses/course-37-docker-internals/challenges/14-custom-bridge/verify.sh
```
