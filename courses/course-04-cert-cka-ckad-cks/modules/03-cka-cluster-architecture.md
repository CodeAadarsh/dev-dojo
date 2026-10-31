# CKA: Cluster Architecture, Nodes & etcd

> **Module 03 · Course 04** — CKAD puts correct apps onto a healthy cluster. CKA is about the cluster *itself*: the control-plane components that make it work, the nodes that run the workloads, and the datastore that remembers all of it. This is the heaviest-weighted ground on the CKA — Cluster Architecture, Installation & Config is 25% and Troubleshooting is 30%, and the two overlap heavily, because most CKA troubleshooting is "a control-plane component or a node is broken, fix it." If you can snapshot and restore etcd, drain and upgrade a node, and repair a kubelet or a static pod that won't start, you've covered the majority of the exam's points.

You run clusters at work, so the architecture won't surprise you. What the CKA adds is the expectation that you operate the control plane *by hand on the node*, not through a managed service's console — SSH to a node, read `crictl`, edit a static pod manifest, run `etcdctl` and `kubeadm` directly. Managed Kubernetes hides all of this; the CKA deliberately strips the abstraction away. This module is that layer.

---

## The control plane, component by component

A kubeadm cluster runs the control-plane components as **static pods** on the control-plane node (more on static pods below), plus a kubelet as a systemd service on every node.

```
┌──────────────────── control-plane node ─────────────────────┐
│  systemd: kubelet ──────────────────┐                        │
│                                      ▼  (reads manifests in   │
│   /etc/kubernetes/manifests/*.yaml → /etc/kubernetes/manifests)│
│   ┌─────────────┐  ┌──────────────┐  ┌───────────────┐       │
│   │ kube-apiserver│ │kube-scheduler│  │ kube-controller│      │
│   │  (the only   │ │  (placement) │  │  -manager      │      │
│   │  thing that  │ └──────────────┘  │ (reconcile loops)│    │
│   │  talks to etcd)│                  └───────────────┘      │
│   └──────┬───────┘                                            │
│          ▼                                                    │
│   ┌─────────────┐                                             │
│   │    etcd     │  the source of truth — ALL cluster state    │
│   └─────────────┘                                             │
└───────────────────────────────────────────────────────────────┘
          ▲ every worker node: kubelet (systemd) + kube-proxy (DaemonSet) + CNI
```

| Component | Job | Runs as | If it's down… |
|---|---|---|---|
| `kube-apiserver` | the front door; the *only* component that reads/writes etcd | static pod | nothing works; `kubectl` returns connection refused |
| `etcd` | key-value store holding **all** cluster state | static pod | apiserver can't start; cluster is amnesiac |
| `kube-scheduler` | assigns Pending pods to nodes | static pod | new pods stay `Pending` forever |
| `kube-controller-manager` | reconcile loops (Deployments→ReplicaSets→Pods, node lifecycle, etc.) | static pod | Deployments don't scale, nodes not marked NotReady, etc. |
| `kubelet` | the node agent; starts containers, reports status | **systemd service** | that node goes `NotReady`; its static pods stop being managed |
| `kube-proxy` | programs iptables/IPVS for Service VIPs | DaemonSet pod | Services stop routing on that node |

> **The single most useful fact for CKA troubleshooting:** the kubelet is **not** a pod — it's a systemd unit (`systemctl status kubelet`). Everything else in the control plane *is* a pod that the kubelet starts from a manifest file. So when the whole control plane is down, you don't debug it with `kubectl` (which needs the apiserver that's down); you SSH to the node and use `systemctl` + `crictl`. That inversion — "when kubectl can't help, drop to the node" — is the backbone of this module.

---

## Static pods — how the control plane boots itself

A **static pod** is a pod the kubelet runs directly from a YAML file on disk, with no apiserver, no scheduler, no controller involved. The kubelet watches a directory and runs whatever manifests it finds there.

```bash
# where the kubelet looks (set in its config):
ls /etc/kubernetes/manifests/
# -> etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml
```

This is a chicken-and-egg solution: the control plane can't schedule itself (the scheduler *is* part of the control plane), so kubeadm runs the control plane as static pods that the kubelet brings up with zero cluster dependencies.

Key behaviours that show up as exam tasks:

- **Edit the manifest → kubelet restarts the pod.** Changing `/etc/kubernetes/manifests/kube-apiserver.yaml` makes the kubelet detect the change and recreate the static pod within seconds. This is how you add a flag to the apiserver (e.g. an admission plugin, an audit-log path) — there is no `kubectl edit` for a static pod's spec; you edit the file on the node.
- **Static pods get a mirror pod in the API.** You *see* them via `kubectl get pods -n kube-system` with the node name appended (`kube-apiserver-dojo-control-plane`), but you can't delete them through the API — delete the manifest file to remove one.
- **To make a static pod of your own:** drop a manifest in the directory. A classic CKA task: "create a static pod named `web` on node X." You write the YAML into `/etc/kubernetes/manifests/web.yaml` on that node and the kubelet runs it.

```bash
# generate a pod manifest and place it as a static pod on the node
kubectl run web --image=nginx:1.27-alpine --dry-run=client -o yaml > /etc/kubernetes/manifests/web.yaml
# (on the node) confirm the kubelet picked it up:
crictl pods | grep web
```

> **Static-pod gotcha:** if you break `kube-apiserver.yaml` (a bad flag, a YAML typo), the apiserver pod won't come back and `kubectl` dies with connection refused. You fix it the same way you broke it — on the node, edit the file back, and watch `crictl ps` until the apiserver container is `Running` again. Keep a backup before editing: `cp kube-apiserver.yaml /tmp/kube-apiserver.yaml.bak`.

---

## Nodes: cordon, drain, and the upgrade flow

Day-2 node operations are a reliable CKA bucket. The three verbs:

| Verb | Effect | Reversible with |
|---|---|---|
| `kubectl cordon <node>` | mark unschedulable; existing pods stay | `kubectl uncordon <node>` |
| `kubectl drain <node>` | cordon **+** evict all pods (respecting PDBs) | `kubectl uncordon <node>` |
| `kubectl uncordon <node>` | mark schedulable again | — |

```bash
kubectl drain dojo-worker \
  --ignore-daemonsets \        # DaemonSet pods can't be rescheduled, so skip them
  --delete-emptydir-data \     # allow evicting pods with emptyDir volumes (data is lost)
  --force                      # evict bare pods not managed by a controller
```

`drain` honours PodDisruptionBudgets — if evicting a pod would violate a PDB, the drain blocks on that pod until a replacement is Ready elsewhere. That's the mechanism from Course 01's "Make It Survive": a PDB turns a drain from "all pods gone at once" into "one at a time as replacements come up."

### The kubeadm node-upgrade flow (memorize the order)

Upgrading a cluster is a near-certain CKA task. The order is rigid: **control plane first, one minor version at a time, drain before, uncordon after.**

```
   control-plane node                         each worker node
   ─────────────────                          ────────────────
   1. kubectl drain <cp> --ignore-daemonsets
   2. apt upgrade kubeadm=1.31.x               1. kubectl drain <w> --ignore-daemonsets ...
   3. kubeadm upgrade plan                      2. (on node) apt upgrade kubeadm=1.31.x
   4. kubeadm upgrade apply v1.31.x             3. (on node) kubeadm upgrade node
   5. apt upgrade kubelet kubectl               4. (on node) apt upgrade kubelet
   6. systemctl restart kubelet                 5. systemctl daemon-reload; restart kubelet
   7. kubectl uncordon <cp>                      6. kubectl uncordon <w>
```

```bash
# control-plane node, concretely (Debian/Ubuntu exam image):
kubectl drain dojo-control-plane --ignore-daemonsets
apt-get update && apt-get install -y kubeadm=1.31.0-1.1
kubeadm upgrade plan                     # shows what it will do + the target version
kubeadm upgrade apply v1.31.0            # upgrades the control-plane components
apt-get install -y kubelet=1.31.0-1.1 kubectl=1.31.0-1.1
systemctl daemon-reload && systemctl restart kubelet
kubectl uncordon dojo-control-plane
```

> **The two mistakes that cost this task:** (1) upgrading `kubelet` *before* running `kubeadm upgrade apply` — the control-plane components must go first; (2) forgetting `systemctl daemon-reload && systemctl restart kubelet` after the apt upgrade, so the node keeps running the old kubelet and `kubectl get nodes` still shows the old version. Always finish with `kubectl get nodes` to confirm the `VERSION` column actually changed.

---

## etcd — snapshot save & restore

etcd is the whole cluster's memory. "Back up etcd" and "restore etcd from this snapshot" are among the most common CKA tasks, and they're pure recall — you either know the exact `etcdctl` invocation or you burn five minutes you don't have.

etcd runs as a static pod on the control-plane node. You talk to it with `etcdctl`, which needs **API v3** and the client certs that are mounted into the etcd pod:

```bash
# SAVE — take a snapshot (run on the control-plane node)
ETCDCTL_API=3 etcdctl snapshot save /opt/etcd-backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# confirm the snapshot
ETCDCTL_API=3 etcdctl snapshot status /opt/etcd-backup.db --write-out=table
```

Restore writes the snapshot into a **new data directory**, then you point etcd at it:

```bash
# RESTORE — into a fresh data dir
ETCDCTL_API=3 etcdctl snapshot restore /opt/etcd-backup.db \
  --data-dir=/var/lib/etcd-restore
```

Then you repoint the etcd static pod at the restored directory and let the kubelet restart it:

```
  1. edit /etc/kubernetes/manifests/etcd.yaml
     - change the hostPath volume that backs /var/lib/etcd
       from  path: /var/lib/etcd
       to    path: /var/lib/etcd-restore
  2. the kubelet sees the manifest change and recreates the etcd pod
  3. the apiserver reconnects to the restored etcd
```

> **The restore gotchas that catch people:** (1) the three certs live under `/etc/kubernetes/pki/etcd/` — the apiserver's *own* client certs (`/etc/kubernetes/pki/apiserver-etcd-client.crt`) also work and are what some exam setups hand you; read the task for which path it gives. (2) Restore does **not** overwrite the live data dir — it writes a new one, and you make it live by editing the static pod's `hostPath`. (3) While etcd is being restored the apiserver will be unavailable, so `kubectl` will error for a bit — that's expected, wait for the etcd container to come back in `crictl ps`. (4) `ETCDCTL_API=3` must be set or you get cryptic v2 errors; newer etcdctl defaults to v3 but set it explicitly so you're never surprised.

---

## kubeconfig & contexts — operating multiple clusters

The CKA exam hands you several clusters and *every task* begins with a `kubectl config use-context <name>` line. Understanding the kubeconfig structure is how you never work in the wrong cluster.

A kubeconfig is three independent lists plus a pointer:

```
  clusters:  [ {name, server-URL, CA} ]          <- WHERE the apiserver is
  users:     [ {name, client-cert/token} ]       <- WHO you auth as
  contexts:  [ {name, cluster, user, namespace} ] <- a named (cluster+user+ns) pairing
  current-context: <one context name>             <- the active pointer
```

```bash
kubectl config get-contexts                 # list; * marks the active one
kubectl config current-context             # the single most important pre-flight command
kubectl config use-context cluster-2       # switch (every CKA task starts with this)
kubectl config set-context --current --namespace=kube-system   # change default ns
kubectl config view --minify                # show just the active context's details
KUBECONFIG=/path/to/file kubectl get nodes  # use a specific kubeconfig for one command
```

> **Context confusion is the number-one avoidable CKA failure.** It never errors — your command runs perfectly, in the wrong cluster, and scores zero. Build the reflex: the first thing you type for every task is the task's own `use-context` line, and before any destructive action you run `kubectl config current-context` and read it. This is the same discipline the dojo's setup scripts enforce by warning when the context isn't `kind-dojo`.

---

## Debugging a NotReady node / broken control-plane component

This is the CKA's largest point bucket, and it's where the "drop to the node with `crictl`" skill pays off. The decision tree:

```
   kubectl works?
   ├─ NO  → control plane / apiserver is down → SSH to control-plane node,
   │         use systemctl + crictl (NOT kubectl)
   └─ YES → a node or a workload is broken → use kubectl describe + logs,
             then SSH to the specific node if it's NotReady
```

| Symptom | Likely cause | Where to look |
|---|---|---|
| `kubectl` → `connection refused` / `was refused` | apiserver static pod down, or wrong context | node: `crictl ps`; local: `kubectl config current-context` |
| One node `NotReady` | kubelet down on that node, or CNI pod not running | SSH that node: `systemctl status kubelet` |
| Node `NotReady`, kubelet running | CNI not ready, or kubelet can't reach apiserver | `crictl ps | grep -E 'kindnet|calico|flannel'`; check kubelet logs |
| All new pods `Pending` | scheduler static pod down | `kubectl -n kube-system get pods | grep scheduler`; node: `crictl ps` |
| Deployments don't scale, nodes never go NotReady | controller-manager down | `kubectl -n kube-system get pods | grep controller`; node logs |
| apiserver won't start after a manifest edit | bad flag / YAML typo in `kube-apiserver.yaml` | node: `crictl logs <apiserver-container-id>` |
| kubelet `inactive (dead)`, won't start | bad `/var/lib/kubelet/config.yaml`, expired certs, swap on | `journalctl -u kubelet -n 50 --no-pager` |

### The exact commands, on the node

Because a broken control plane means `kubectl` is useless, you work with the container runtime directly. On a kind node you first `docker exec` into the node container (kind's nodes are containers), then use `crictl` and `systemctl`:

```bash
# get onto the node (kind: the node is a docker container)
docker exec -it dojo-control-plane bash
#   on a real exam cluster this is: ssh <node>

# 1. is the kubelet even running? (it's systemd, not a pod)
systemctl status kubelet
journalctl -u kubelet -n 50 --no-pager           # the logs that explain WHY it won't start

# 2. what containers does the runtime actually have? (crictl, not kubectl)
crictl ps -a                                      # -a shows exited/crashed containers too
crictl ps -a | grep apiserver                     # is the apiserver container up?

# 3. why did a control-plane container die? read ITS logs by id
crictl logs <container-id>                        # e.g. the crashed kube-apiserver
crictl logs --previous <container-id>             # logs from before the last restart

# 4. the static-pod manifests the kubelet is trying to run
cat /etc/kubernetes/manifests/kube-apiserver.yaml
ls -la /etc/kubernetes/manifests/
```

Three concrete repair patterns the exam reuses:

**A. kubelet won't start.** Read `journalctl -u kubelet` — it names the cause. The usual suspects: swap is on (`swapoff -a` + remove from `/etc/fstab`), a typo in `/var/lib/kubelet/config.yaml`, or the kubelet config points at a kubeconfig/CA that doesn't exist. Fix, then:

```bash
systemctl daemon-reload && systemctl restart kubelet && systemctl status kubelet
```

**B. apiserver down after a manifest edit.** The kubelet is trying to run a broken static pod. `crictl logs` the crash-looping apiserver container to see the exact rejected flag, fix `/etc/kubernetes/manifests/kube-apiserver.yaml`, and watch `crictl ps` until it's `Running`:

```bash
crictl ps -a | grep apiserver                     # find the (probably Exited) container
crictl logs <id> 2>&1 | tail -20                  # "unknown flag: --oops" etc.
# fix the manifest, then it self-heals:
crictl ps | grep apiserver                        # wait for Running
```

**C. node NotReady because CNI is down.** The kubelet is up but the node has no pod network. Check the CNI DaemonSet pods and the kubelet's complaint:

```bash
kubectl -n kube-system get pods -o wide | grep -E 'kindnet|calico|flannel|cilium'
journalctl -u kubelet -n 30 --no-pager | grep -i 'cni\|network'
```

> **War story.** On the LGTM pipeline at SAP, a worker node went `NotReady` in the middle of a rollout and half the log-ingest pods stopped reporting. The dashboards were screaming, and my first instinct — muscle memory from a managed cluster — was to `kubectl describe node` and `kubectl logs` the kubelet. But you can't `kubectl logs` a kubelet: it isn't a pod. I burned ten minutes chasing pod logs that didn't exist before I remembered the inversion — the kubelet is a *systemd service on the node*. One `ssh` + `journalctl -u kubelet -n 50` and the cause was right there: the node's disk had filled with container logs, the kubelet had flipped the node to `DiskPressure`, and it was evicting pods to claw back space. The fix was a log-rotation config, not anything in Kubernetes at all. The lesson the CKA drills into you for a reason: **when a node is sick, the answer is on the node, in `journalctl -u kubelet` and `crictl`, not in `kubectl`.** `kubectl` talks to the apiserver about desired state; the node's own logs tell you why reality disagrees.

---

## Checkpoint

You're ready for the cluster-architecture drills when you can, without looking anything up:

1. Name the five control-plane components, which one is the *only* one that talks to etcd, and which single component is a systemd service rather than a static pod.
2. Explain what a static pod is, where its manifests live (`/etc/kubernetes/manifests/`), how you edit the apiserver's flags, and why you can't `kubectl delete` one.
3. Give the full kubeadm upgrade order (drain → kubeadm → control-plane apply → kubelet → restart → uncordon) and the two mistakes that zero the task.
4. Write the `etcdctl snapshot save` and `snapshot restore` commands from memory, including which three certs they need and which directory a restore writes to.
5. Explain how `drain` interacts with a PodDisruptionBudget, and why `--ignore-daemonsets` is almost always required.
6. State the decision rule for a broken cluster: if `kubectl` works, use `describe`/`logs`; if it doesn't, SSH the node and use `systemctl` + `crictl`.
7. Diagnose a `NotReady` node three ways — kubelet down (`journalctl -u kubelet`), apiserver static pod broken (`crictl logs <id>`), and CNI not running (`kubectl -n kube-system get pods`).
8. Say why context confusion is more dangerous than an outright error, and name the one command you run before any destructive action.

➡ You've now covered the two heaviest exams end-to-end: CKAD's workload shapes (Module 02) and CKA's cluster internals (this module). The challenges in this course turn that knowledge into timed muscle memory — start the clock and prove it.
