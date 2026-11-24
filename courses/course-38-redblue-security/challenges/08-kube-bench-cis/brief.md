# kube-bench CIS Hardening

The CIS Kubernetes Benchmark is the gold standard for K8s security hardening. It defines 200+ controls across the API server, etcd, kubelet, scheduler, and controller manager. `kube-bench` automates checking these controls.

In production, an unaudited cluster almost certainly has critical findings — anonymous API access, insecure defaults, missing audit logging, kubelet authorization disabled. This challenge teaches you to run `kube-bench`, interpret its output, and fix the highest-severity findings.

## CIS Benchmark Categories

```
┌─────────────────────────────────────────────────────────┐
│               CIS Kubernetes Benchmark v1.9             │
├─────────────────────────────────────────────────────────┤
│  Section 1: Control Plane Components                    │
│    1.1  API Server         ← 20+ checks                 │
│    1.2  Scheduler          ← 2 checks                   │
│    1.3  Controller Manager ← 7 checks                   │
│    1.4  etcd               ← 7 checks                   │
│                                                          │
│  Section 2: etcd           ← TLS, auth, permissions     │
│                                                          │
│  Section 3: Control Plane Config                        │
│                                                          │
│  Section 4: Worker Nodes                                │
│    4.1  Worker Node Config Files                        │
│    4.2  Kubelet            ← 13 checks                  │
│                                                          │
│  Section 5: Kubernetes Policies                         │
│    5.1  RBAC               ← 9 checks                   │
│    5.2  Pod Security       ← 9 checks                   │
│    5.3  Network Policies   ← 2 checks                   │
│    5.4  Secrets Management ← 2 checks                   │
│    5.5  Extensible Admission Control                    │
│    5.7  General Policies   ← 4 checks                   │
└─────────────────────────────────────────────────────────┘
```

## Common FAIL Findings and What They Mean

| ID | Finding | Risk |
|----|---------|------|
| 1.2.1 | `--anonymous-auth=true` on API server | Unauthenticated access to the API |
| 1.2.6 | No AlwaysPullImages admission controller | Pods can use cached images bypassing registry auth |
| 4.2.2 | `--authorization-mode=AlwaysAllow` on kubelet | Any caller can execute anything on the node |
| 5.1.1 | Cluster-admin bindings exist | Over-privileged accounts |
| 5.2.1 | Privileged pods allowed | Containers can escape to host |

## Mission

1. Run `kube-bench` in namespace `dojo-sec-bench` against the cluster
2. Find the failing checks in the simulated bench output
3. For each FAIL, write the remediation command or config change
4. Apply the fix for one specific finding (5.1.1 — cluster-admin binding to a non-system account)
5. The flag is in a ConfigMap that only unlocks once you delete the offending ClusterRoleBinding

## Target State

- Delete the `overprivileged-binding` ClusterRoleBinding from namespace `dojo-sec-bench`
- Once deleted, a watcher pod creates the flag ConfigMap
- Retrieve the flag
