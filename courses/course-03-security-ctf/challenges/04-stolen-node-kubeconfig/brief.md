# Keys to the Kingdom

A platform team shipped a node-level agent — the kind of thing that reads cgroup stats or ships logs — and, to make a stubborn mount error go away, someone gave it `hostPath: /` and a toleration so it would run *everywhere*, including the control-plane node. It passed review because "it only reads metrics." You are now standing where an attacker stands after compromising that agent's image: a shell inside a pod that can read the node's entire filesystem, on the one node where the crown jewels live.

The pod's own identity is almost worthless. Its ServiceAccount (`default` in `dojo-steal`) has **no** RBAC anywhere near the flag. But the pod mounts the node's root filesystem, and on a control-plane node that filesystem holds a file that is worth more than any ServiceAccount token: **`/etc/kubernetes/admin.conf` — a `cluster-admin` kubeconfig.** Node access is cluster-admin-equivalent *regardless of what RBAC says*, and this challenge makes that sentence concrete.

## The scenario the setup script plants

| Object | Detail |
|--------|--------|
| Namespace `dojo-steal` | Permissive namespace — no Pod Security Admission label, so a `hostPath` pod is allowed |
| Pod `foothold` | `nicolaka/netshoot:v0.13`, mounts `hostPath: /` at `/host`, pinned to the **control-plane** node (tolerates its `NoSchedule` taint) |
| Namespace `dojo-vault` | Locked down with **PSA `restricted`** — you cannot schedule an escape pod *into* it |
| Secret `kingdom-keys` | Lives in `dojo-vault`, holds `FLAG=KUBE{...}` plus a decoy `TLS_PRIVATE_KEY` |
| RBAC | `foothold`'s ServiceAccount (`system:serviceaccount:dojo-steal:default`) has **no** access to Secrets in `dojo-vault` |

Prove the starting point first — the pod's own identity is a dead end:

```bash
kubectl auth can-i get secrets -n dojo-vault \
  --as=system:serviceaccount:dojo-steal:default
# -> no
```

That `no` is the whole point. Everything you recover, you recover with a *stolen* credential, not the one the pod was issued.

## The escalation, drawn

```
┌─ pod: foothold (ns dojo-steal) ──────────────────────────────────────┐
│  its own SA  ──✗──▶  Secret in dojo-vault        (RBAC says: no)       │
│                                                                       │
│  hostPath: /  ──▶  /host/etc/kubernetes/admin.conf                    │
│                         │                                             │
│                         └─▶ cluster-admin client cert + key           │
│                                   │                                   │
│                                   ▼                                   │
│  curl https://kubernetes.default.svc  (as cluster-admin)  ──▶  FLAG   │
└───────────────────────────────────────────────────────────────────────┘
      the mount is the whole attack. RBAC never gets a vote.
```

## Mission

From inside the `foothold` pod:

1. Read the node's `cluster-admin` kubeconfig off the mounted host filesystem (`/host/etc/kubernetes/admin.conf`).
2. **Use** that credential — not the pod's own token — to read the `kingdom-keys` Secret in the restricted `dojo-vault` namespace.
3. Decode the flag (Secret values are base64, not encrypted — Course 01's lesson).

There is more than one legitimate route once you hold the node:

- **The kubeconfig path (intended):** extract the admin client cert/key from `admin.conf` and present them to the in-cluster API server at `https://kubernetes.default.svc`.
- **The etcd path (bonus):** on a control-plane node, etcd's client certs sit right beside the kubeconfig under `/host/etc/kubernetes/pki/etcd/` — you can read the Secret straight out of etcd, bypassing the API server entirely (Course 03, Challenge 03's lesson, reached here by escape instead of `docker exec`).
- **The exfil path:** copy `admin.conf` off the node and use it with `kubectl --kubeconfig` from any machine that can reach the API server.

Submit the `KUBE{...}` flag you recover.

## Why this matters

This is the hinge the whole course has been building toward: the moment a container escape stops being "a shell in a pod" and becomes "owner of the cluster." Two independent failures line up here, and either one being fixed would have stopped you cold:

- **A workload was allowed to request `hostPath: /`.** That alone reads every file on the node — including other pods' decrypted Secrets in `/var/lib/kubelet/pods` and, on a control-plane node, the admin kubeconfig.
- **That workload was allowed onto the control-plane node.** The `node-role.kubernetes.io/control-plane:NoSchedule` taint exists precisely to keep untrusted pods off the node that holds `admin.conf`; a careless toleration erased it.

RBAC is an API-server control. It is invisible to a process reading files on the node. No scoping of the pod's ServiceAccount could have protected `kingdom-keys` once the pod could read `admin.conf` — the defense lives *below* RBAC, in admission policy and node hygiene. You'll place that defense in the solution.
