# Solution — Pivot Through the Pod

The flag is `KUBE{flat_network_enables_lateral_movement}`. Below is the direct capture, the enumerate-first path an attacker who wasn't handed the target name would use, the failure modes, and the default-deny `NetworkPolicy` that closes it — plus the kind-specific caveat that makes policy do nothing if you miss it.

## Step 0 — get your shell on the foothold

```bash
kubectl -n dojo-lateral exec -it foothold -- bash
```

Everything below runs **inside** `foothold`. You have no token, no node access — only a network interface on the cluster's flat fabric. Watch how far that goes.

## Step 1 — the direct capture

You were told the Service name. Resolve it and read it:

```bash
curl -s http://internal-api.dojo-lateral.svc.cluster.local/
# ...
# <p>FLAG=KUBE{flat_network_enables_lateral_movement}</p>
# ...

# just the flag:
curl -s http://internal-api.dojo-lateral.svc.cluster.local/ | grep -o 'KUBE{[^}]*}'
# -> KUBE{flat_network_enables_lateral_movement}
```

Nothing authenticated you. Nothing authorized the connection. A pod in `dojo-lateral` reached another pod in `dojo-lateral` because the default pod network permits it — full stop.

## Step 2 — the enumerate-first path (what a real intruder does)

An attacker isn't handed the Service name. They derive it. CoreDNS is a free map of the cluster:

```bash
# Who is my resolver, and what's my search domain?
cat /etc/resolv.conf
# nameserver 10.96.0.10
# search dojo-lateral.svc.cluster.local svc.cluster.local cluster.local

# Thanks to the search domain, the short name resolves — no FQDN needed:
dig +short internal-api
dig +short internal-api.dojo-lateral.svc.cluster.local
# -> 10.96.x.y  (the ClusterIP)
```

Confirm the port is open and fingerprint it, then connect to the raw IP — no DNS required at all:

```bash
IP=$(dig +short internal-api.dojo-lateral.svc.cluster.local)
nmap -Pn -p 80 "$IP"                 # netshoot ships nmap
curl -s "http://$IP/" | grep -o 'KUBE{[^}]*}'
# -> KUBE{flat_network_enables_lateral_movement}
```

In a cluster with other namespaces, the same reverse-walk from Module 06 (`dig -x` across the Service CIDR) would surface Services in namespaces your RBAC can't even `list`. Lateral recon, zero API calls.

## Common failure modes

| What you see | Cause | Fix |
|--------------|-------|-----|
| `curl: (6) Could not resolve host` | Used the short name but egress to CoreDNS is blocked, or wrong FQDN | Use the full `internal-api.dojo-lateral.svc.cluster.local`, or hit the ClusterIP directly |
| `curl: (7) Connection refused` | Wrong port, or pods not Ready yet | `kubectl -n dojo-lateral get pod,svc`; the Service is `:80`; wait for `internal-api` rollout |
| `curl` **hangs then times out** | A `NetworkPolicy` is now enforcing a deny (you've started the defense) and an enforcing CNI is installed | Expected after hardening — a hang is a *working* block, not a bug |
| Empty page, no flag | `grep` pattern too tight, or hit the wrong Service | Fetch the whole body: `curl -s http://internal-api.dojo-lateral.svc.cluster.local/` and read it |
| DNS works but connect fails only for *some* targets | Partial policy already applied | `kubectl -n dojo-lateral get netpol` to see what's selecting what |

> **War story.** During a red-team exercise against a pre-prod cluster, the team scoped the engagement to "can you get out of a pod." They popped a low-value image-resizing worker through a dependency CVE — a pod with a near-empty ServiceAccount and nothing worth stealing locally. Game over in fifteen minutes anyway: from that worker they `dig`-walked the Service CIDR, found a `billing-internal` API that "only the checkout service calls," and pulled customer records straight off it over plain HTTP. No token, no privilege escalation, no node escape — just the flat network and an internal service that treated "inside the cluster" as "authenticated." The remediation wasn't "patch the worker"; it was a namespace default-deny plus authn on the internal API. The lesson the report led with: **every internal service must assume the caller is hostile, because on a flat network the caller eventually is.**

## The defense — default-deny, then punch precise holes

`NetworkPolicy` is the firewall the flat network lacks. The rule that governs everything: **policies are additive allowlists that only take effect once a policy selects a pod.** A pod selected by *zero* policies is allow-all; a pod selected by *any* policy is deny-all except what the matching policies permit. So you start by selecting everything with a deny, then re-allow only what's genuinely needed.

### 1. Default-deny the whole namespace (ingress *and* egress)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: dojo-lateral
spec:
  podSelector: {}            # selects EVERY pod in the namespace
  policyTypes:
    - Ingress
    - Egress
```

With this applied, `foothold` can neither reach `internal-api` nor resolve DNS. The pivot in Step 1/2 now hangs and times out — that hang is the control working.

### 2. Re-allow only the real caller to reach internal-api

The internal API should accept traffic from its frontend and nothing else. Label the legitimate client `app: frontend` and scope ingress to it:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: internal-api-allow-frontend
  namespace: dojo-lateral
spec:
  podSelector:
    matchLabels:
      app: internal-api
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend      # only the frontend — NOT foothold
      ports:
        - { protocol: TCP, port: 80 }
```

`foothold` carries `app: foothold`, not `app: frontend`, so it is no longer an allowed source — the flag becomes unreachable from the compromised pod.

### 3. Don't forget DNS egress (the mistake everyone makes)

The moment you default-deny **egress**, pods can't reach CoreDNS and *every* name lookup fails before the real connection is attempted. Re-allow port 53 to `kube-system/kube-dns` for any pod that needs to resolve names:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: dojo-lateral
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
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

> **`namespaceSelector` + `podSelector` in one `from`/`to` list item is an AND**, not an OR. The block above correctly means "pods labelled `k8s-app: kube-dns` *in* the `kube-system` namespace." Split them into two separate list items only if you mean OR — getting this wrong is the difference between a tight policy and one that accidentally allows the whole cluster.

## The caveat that eats hours: kindnet does not enforce NetworkPolicy

Specific to your lab: **kind's default CNI, `kindnet`, provides pod networking but does *not* implement `NetworkPolicy`.** Your policy objects apply cleanly, `kubectl get netpol` lists them, `describe` looks perfect — and the `curl` pivot still succeeds, because nothing is reading the rules. You will "test" your default-deny, watch it fail to block anything, and blame your YAML when the YAML was never the problem.

```bash
# Which CNI is actually enforcing? On stock kind:
kubectl -n kube-system get pods -o wide | grep -E 'kindnet|calico|cilium'
# kindnet-xxxxx present  -> NetworkPolicy is NOT enforced
```

To make policy real, recreate the dojo with the default CNI disabled and install one that enforces — Calico is the usual choice (pin the version, never a moving ref):

```bash
# kind config: networking: { disableDefaultCNI: true, podSubnet: "192.168.0.0/16" }
# then recreate, then:
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
kubectl -n kube-system rollout status ds/calico-node --timeout=120s
```

### Prove the block from the attacker's seat

With an enforcing CNI and the policies applied, re-run the pivot. A timeout is a *working* deny; an immediate reply means the hole is still open:

```bash
kubectl -n dojo-lateral exec -it foothold -- \
  sh -c 'curl -s --max-time 4 http://internal-api.dojo-lateral.svc.cluster.local/ || echo BLOCKED'
# BLOCKED (hang -> timeout) = policy enforced.  flag printed = still open.
```

The lesson generalizes far past the lab: **a `NetworkPolicy` you haven't watched *block* real traffic on the *enforcing* CNI is an untested `NetworkPolicy`** — and an internal service that relies on network reachability for its security needs authentication anyway, because the network boundary is only ever as real as the CNI enforcing it.
