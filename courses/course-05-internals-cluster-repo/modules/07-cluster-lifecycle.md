# Cluster Lifecycle & Node Operations

> **Module 07 · Course 05** — You know how the control plane works (Module 01) and how to save its memory (Module 04). Now you run the cluster across *time*: born by `kubeadm`, upgraded version by version, nodes cordoned and drained for maintenance, members added and removed, and — when a region burns down — restored from an etcd snapshot plus a Git repo. This is the operator's seat. The difference between competent and expert here is almost entirely about **sequencing**: upgrade in the wrong order, drain without respecting a PDB, or restore etcd onto a live member, and you turn routine maintenance into a Sev-2.

You already drain nodes at work. What this module drills is *why* each step is ordered the way it is, what the exact failure looks like when you skip a step, and the commands to recover — on a `kind` cluster where every "node" is a container you can `docker exec` into and inspect.

---

## kubeadm is the model — kind just automates it

Almost every self-managed cluster (and every CKA exam cluster, and your `kind` dojo) is a **kubeadm** cluster. kubeadm is not a cluster *manager* — it's a one-shot bootstrapper that:

1. Generates the PKI under `/etc/kubernetes/pki` (CA, api-server, etcd, kubelet certs).
2. Writes the four control-plane **static-pod manifests** into `/etc/kubernetes/manifests` (etcd, apiserver, controller-manager, scheduler — see Module 01).
3. Bootstraps the kubelet, brings up the control plane, and installs core addons (CoreDNS, kube-proxy).
4. Hands you a `kubeadm join` command (with a token + CA hash) for workers to enroll.

`kind` runs `kubeadm init` inside the `dojo-control-plane` container and `kubeadm join` inside each worker container. Everything kubeadm touches on a real node is right there to inspect:

```bash
docker exec dojo-control-plane ls /etc/kubernetes/manifests          # the 4 static pods
docker exec dojo-control-plane cat /etc/kubernetes/kubeadm-flags.env # kubelet runtime flags
docker exec dojo-control-plane kubeadm config print init-defaults    # the config kubeadm uses
docker exec dojo-control-plane kubeadm token list                    # join tokens (24h TTL by default)
```

The mental model that pays off: **kubeadm manages component *versions and config*, the kubelet runs the static pods, and nothing self-heals the control plane's version.** Upgrading is *you* driving kubeadm, node by node, in a specific order.

---

## Version skew: the rules that make "upgrade one minor at a time" non-negotiable

Kubernetes components don't all have to be the same version, but the allowed gaps are tight and asymmetric. `kube-apiserver` is the reference point everything else is measured against.

| Component | Allowed skew vs the **oldest** api-server | In plain terms |
|-----------|-------------------------------------------|----------------|
| `kube-apiserver` (HA peers) | within **1** minor of each other | mixed-version control plane only during an upgrade |
| `kube-controller-manager`, `kube-scheduler`, `cloud-controller-manager` | up to **1 minor older**, never newer | control-plane loops may lag the apiserver by one |
| `kubelet` | up to **3 minors older**, never newer | nodes can lag the apiserver by three (relaxed from 2 in recent releases) |
| `kube-proxy` | matches its node's kubelet band | node agent tracks the kubelet |
| `kubectl` | within **1 minor** either side of the apiserver | your CLI can be one ahead or behind |

Two hard consequences:

- **Never skip a minor.** You go 1.29 → 1.30 → 1.31, never 1.29 → 1.31. The control plane and kubelets would exceed skew mid-way, and kubeadm will refuse.
- **The api-server upgrades first, always.** Nothing is allowed to be *newer* than the api-server, so the api-server must lead and everything else follows. Upgrade a kubelet past the api-server and that node's kubelet starts rejecting api-server responses it can't parse.

```bash
# the versions you actually have right now
kubectl version -o json | grep -E 'gitVersion'    # client + server
kubectl get nodes -o wide                          # VERSION column = each kubelet's version
```

> **Why "never newer" is strict.** The api-server is the schema authority. A newer kubelet or controller may send the api-server fields it doesn't understand, or expect response shapes the older api-server can't produce. Older-talking-to-newer is tested and supported; newer-talking-to-older is not. Memorize the direction, not just the numbers.

---

## Upgrading a cluster: control plane first, then nodes

You never upgrade "the cluster" in one shot. You upgrade **one control-plane node to set the target version, then the remaining control-plane nodes, then the workers one at a time**, draining each first. Conceptually (don't run this against the dojo — it's a throwaway you recreate, not upgrade):

```
Phase 1 — first control-plane node (sets the cluster's target version)
  apt/yum: install kubeadm=1.30.x
  kubeadm upgrade plan                 # shows what will change, checks skew + addons
  kubeadm upgrade apply v1.30.x        # upgrades apiserver/cm/scheduler static pods + etcd + addons
  install kubelet=1.30.x + kubectl; systemctl restart kubelet

Phase 2 — each additional control-plane node
  install kubeadm=1.30.x
  kubeadm upgrade node                 # NOT "apply" — joins the already-set target
  install kubelet=1.30.x; restart kubelet

Phase 3 — each worker, one at a time
  kubectl drain <node> --ignore-daemonsets --delete-emptydir-data   # from an admin box
  (on the node) install kubeadm; kubeadm upgrade node; install kubelet; restart kubelet
  kubectl uncordon <node>              # put it back in rotation, verify Ready, then next node
```

Why this exact order:

- **`kubeadm upgrade apply` runs once, on the first control-plane node**, because that's what rewrites the cluster's component versions in the config. Every other node runs `kubeadm upgrade node`, which reads that already-decided target.
- **Workers are drained before their kubelet restarts** so the restart doesn't bounce live traffic. One node at a time keeps capacity up and respects PodDisruptionBudgets.
- **etcd is upgraded as part of `upgrade apply`** (it's a static pod kubeadm owns). Take an etcd snapshot *before* you start — upgrades are the single most common reason you'll ever actually need the restore path from Module 04.

On `kind` the "upgrade" path is simpler and brutal: you don't upgrade, you **recreate** at the new version. That's the whole point of a dojo — the cluster is cattle.

```bash
kind create cluster --name dojo --image kindest/node:v1.31.0 --config labs/bootstrap/kind-config.yaml
```

---

## Node operations: cordon, drain, uncordon, taint

These four verbs are your maintenance toolkit. Know exactly what each one changes on the Node object.

| Verb | What it sets on the Node | Effect | Undo |
|------|--------------------------|--------|------|
| `cordon` | `spec.unschedulable: true` | **No new pods** scheduled here; existing pods keep running | `uncordon` |
| `drain` | cordon **+** evicts existing pods | empties the node for maintenance, honoring PDBs | `uncordon` (pods reschedule elsewhere / back) |
| `uncordon` | `spec.unschedulable: false` | node accepts new pods again | — |
| `taint` | adds `spec.taints[]` | repels pods that lack a matching **toleration** | `taint ... key-` (trailing `-` removes) |

The drain-for-maintenance dance you'll run a hundred times:

```bash
kubectl cordon dojo-worker2                              # stop new placements immediately
kubectl drain dojo-worker2 \
  --ignore-daemonsets \                                  # DaemonSet pods can't move; expected
  --delete-emptydir-data                                 # consent to lose emptyDir scratch data
# ... do the maintenance (restart kubelet, patch the host) ...
kubectl uncordon dojo-worker2                            # back into rotation
kubectl get nodes                                        # confirm it's Ready + not SchedulingDisabled
```

**Drain and PodDisruptionBudgets are a pair.** A drain issues the **Eviction API** for each pod, and the Eviction API *respects PDBs*. If evicting a pod would push a protected workload below its `minAvailable`, the eviction is **denied**, and `drain` blocks and retries until a replacement pod becomes Ready elsewhere. That's the mechanism that makes "the Make It Survive challenge" matter: a Deployment with 3 replicas, `maxUnavailable: 0`, and a PDB of `minAvailable: 2` drains gracefully pod-by-pod; the same app at 1 replica with a `minAvailable: 1` PDB **can never be drained** — more on that in Debugging.

**Taints vs cordon.** Cordon is a blunt "no new pods, period." A taint is selective: `NoSchedule` repels pods *without a matching toleration*, so you can keep a node for GPU/spot/control-plane workloads only. The three effects:

```bash
kubectl taint nodes dojo-worker gpu=true:NoSchedule      # new pods need a matching toleration
kubectl taint nodes dojo-worker gpu=true:NoExecute       # ALSO evicts running pods lacking it
kubectl taint nodes dojo-worker gpu=true:PreferNoSchedule # soft: avoid if possible, not a hard bar
kubectl taint nodes dojo-worker gpu-                     # remove the taint (trailing dash)
```

The control-plane node carries `node-role.kubernetes.io/control-plane:NoSchedule` out of the box — that's the taint keeping your workloads off the master. Inspect it:

```bash
kubectl get node dojo-control-plane -o jsonpath='{.spec.taints}{"\n"}'
```

---

## Adding and removing nodes

**Add** a node = `kubeadm join` with a current token + CA hash. On a real cluster you mint the join command on the control plane:

```bash
# on the control plane — prints a ready-to-paste `kubeadm join ...` with a fresh 24h token
docker exec dojo-control-plane kubeadm token create --print-join-command
```

On `kind`, you don't `kubeadm join` by hand — you declare the node in `kind-config.yaml` and recreate, or (rarely) `docker run` a node into the kind network. For the dojo, editing `labs/bootstrap/kind-config.yaml` to add a third `- role: worker` and recreating is the clean path.

**Remove** a node = drain it, delete the Node object, then tear down its kubeadm state so it doesn't try to rejoin:

```bash
kubectl drain dojo-worker2 --ignore-daemonsets --delete-emptydir-data
kubectl delete node dojo-worker2                         # removes it from the api-server's view
# on the node being retired (real cluster):
#   kubeadm reset -f        # wipes /etc/kubernetes, certs, and the kubelet's state
```

Order matters: **drain → delete node object → `kubeadm reset`**. Delete the Node object before draining and you orphan running pods the scheduler no longer tracks; skip `kubeadm reset` and a rebooted host rejoins with stale certs.

---

## Multiple clusters: kubeconfig contexts without the footguns

You run the dojo *and* work clusters. A kubeconfig is three lists — `clusters` (where), `users` (how to auth), `contexts` (a named cluster+user+namespace triple). The danger is never a single file; it's **merging** several and losing track of which context is live.

```bash
kubectl config get-contexts                 # the * marks the active one — look before every scary command
kubectl config use-context kind-dojo        # switch active context
kubectl config current-context              # the one command you run before any delete/scale/apply
```

**Merging** configs is just a `KUBECONFIG` path with multiple files; `kubectl` flattens them in order:

```bash
# temporary merge for this shell — later files' contexts are added, not overwritten
export KUBECONFIG="$HOME/.kube/config:$HOME/.kube/work-cluster.yaml:$HOME/.kube/dojo.yaml"
kubectl config get-contexts                 # all contexts from all three files

# bake the merge into one real file
KUBECONFIG="$HOME/.kube/config:$HOME/.kube/work-cluster.yaml" \
  kubectl config view --flatten > ~/.kube/merged && mv ~/.kube/merged ~/.kube/config
```

Three habits that prevent the "wrong cluster" disaster:

- **Per-cluster isolation when it matters.** For anything destructive against a work cluster, use an explicit `--context` on the command, or a dedicated `KUBECONFIG=~/.kube/work.yaml` env in that shell only — never rely on whatever `current-context` happens to be.
- **Namespace in the context.** `kubectl config set-context --current --namespace=dojo-maint` so you stop typing `-n` and stop forgetting it.
- **Prompt integration.** `kubectx`/`kubens` or a shell prompt that prints the current context turns "which cluster am I on?" from a question into a glance.

```bash
kubectl config use-context kind-dojo
kubectl config set-context --current --namespace=default
```

---

## Backup & restore strategy: etcd for state, Git for intent

A real DR plan has **two** legs, and they recover different things:

| Leg | Captures | Restores | Cadence |
|-----|----------|----------|---------|
| **etcd snapshot** | the *entire live cluster state* — every object, status, Secret, lease | the cluster exactly as it was at snapshot time | scheduled (e.g. hourly CronJob), stored **off-cluster** |
| **GitOps repo** | the *declared desired state* — your manifests/Helm/Kustomize | re-applies everything a controller then reconciles | every commit (it *is* your source of truth) |

They're complementary. etcd restore is fast and total but includes drift, orphaned objects, and anything someone `kubectl edit`-ed by hand. GitOps rebuild is clean and auditable but only recovers what's actually committed — anything created imperatively is gone (which is a feature: it pressures you to commit everything). The expert answer to "what's your backup?" is **both**: snapshot etcd for fast same-cluster recovery, and keep a GitOps repo so you can rebuild a cluster from an empty one.

```bash
# the snapshot (full recipe + restore flow lives in Module 04)
docker exec dojo-control-plane sh -c '
  ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    snapshot save /var/lib/etcd-snapshot.db'
docker cp dojo-control-plane:/var/lib/etcd-snapshot.db ./etcd-snapshot.db   # OFF the node
```

The rule from Module 04 still binds: a snapshot on the node you're backing up is not a backup, and an untested restore is a hope, not a plan.

---

## Debugging cluster lifecycle & node operations

Lifecycle failures are almost all **ordering and skew** problems, and they share a trait: the error is loud and specific if you read it. Triage table first.

| Symptom | Likely cause | Fix / confirm |
|---------|--------------|---------------|
| `kubectl drain` hangs: `Cannot evict pod as it would violate the disruption budget` | PDB `minAvailable` already at the limit; no room to evict one more | add replicas / lower `minAvailable` so a replacement can come up, or drain the node it reschedules onto last |
| `drain` refuses: `pods ... not managed by ReplicationController, ReplicaSet, Job, DaemonSet or StatefulSet` | a bare (static or orphan) pod with no controller to recreate it | `--force` to evict (it won't come back), or move the workload under a controller first |
| `drain` loops forever on one pod | PDB with `minAvailable: N` on an app with exactly `N` replicas → math can never satisfy | this app is undrainable by design; scale up first, then drain |
| `kubeadm upgrade apply` aborts: `specified version ... is too new / skips a minor` | trying to jump more than one minor, or a component newer than the api-server | upgrade one minor at a time; upgrade the api-server first |
| node `NotReady` after a kubelet restart | kubelet crash, CNI down, or version skew past the 3-minor window | read the kubelet journal on the node; check the kubelet VERSION vs api-server |
| Everything you `apply` lands nowhere / on the wrong cluster | `current-context` points at a different (merged) cluster | `kubectl config current-context`; `use-context kind-dojo` |
| Node stuck `SchedulingDisabled`, no new pods land | left cordoned after maintenance | `kubectl uncordon <node>` |
| New node never appears / `kubeadm join` fails: `token ... expired` | join token's 24h TTL lapsed | `kubeadm token create --print-join-command` for a fresh one |

### Diagnose each — the exact commands

**Drain stuck on a PDB.** Find out *which* budget is blocking and whether it's even satisfiable:

```bash
kubectl get pdb -A                                       # ALLOWED DISRUPTIONS = 0 is the blocker
kubectl -n <ns> describe pdb <name>                      # events say which pod eviction it denied
kubectl -n <ns> get deploy,sts -o wide                   # replicas vs the PDB's minAvailable
# the tell: minAvailable == current replicas → 0 allowed disruptions → undrainable until you scale up
```

**Drain stuck on an unmanaged pod.** Identify the bare pod before you reach for `--force`:

```bash
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" owner="}{.metadata.ownerReferences[0].kind}{"\n"}{end}' | grep -v 'owner=' 
# anything with an empty owner= is a bare pod --force will delete for good
```

**Version-skew failure.** The api-server version is the yardstick; compare every kubelet to it:

```bash
kubectl version -o json | grep gitVersion                # server (api-server) version
kubectl get nodes -o wide                                # VERSION column per kubelet
# on kind, inspect a node's kubelet directly:
docker exec dojo-worker kubelet --version
```

**Node NotReady.** On `kind`, drop to the node container and read the kubelet's own journal — it says *why* it can't go Ready (CNI, disk, cgroup):

```bash
kubectl describe node dojo-worker | sed -n '/Conditions:/,/Addresses:/p'
docker exec dojo-worker journalctl -u kubelet --no-pager | tail -40
kubectl -n kube-system get pods -o wide | grep -E "kindnet|kube-proxy" | grep dojo-worker
```

**Context mix-up.** The only safe reflex before anything destructive:

```bash
kubectl config current-context                           # run this FIRST, every time
kubectl config get-contexts                              # * is active; is it the one you think?
kubectl cluster-info --context kind-dojo                 # pin the context when you're unsure
```

> **War story.** A colleague was draining a worker during a routine kernel patch and the `drain` just... sat there, printing `evicting pod ... / error when evicting: would violate disruption budget` on a loop. He assumed the node was wedged and `--force`-killed the pods to "unstick" it. Two of them belonged to a 2-replica payments service with a `minAvailable: 2` PDB — the PDB was doing *exactly its job*, refusing to let both replicas die at once, and `--force` walked straight past it. The service went to zero mid-afternoon, the drain had simply been waiting for the on-call to add a third replica so eviction had somewhere to go. The lesson burned in: **a drain that blocks on a PDB is the system protecting you, not a bug to override.** When `ALLOWED DISRUPTIONS: 0`, the fix is capacity (scale up, or drain the node the pod would reschedule onto *last*), never `--force`. `--force` on a PDB-blocked drain is how you convert graceful maintenance into an outage.

---

## Checkpoint

You own this module when you can, without looking anything up:

1. Explain what `kubeadm` does (and doesn't) manage, and point at the static-pod manifests and PKI it created on the lab node.
2. Recite the version-skew bands (apiserver → controllers/scheduler 1 older, kubelet 3 older, never newer) and explain why the api-server always upgrades first and you never skip a minor.
3. Order a cluster upgrade: first control-plane (`upgrade apply`) → other control-plane (`upgrade node`) → drain+upgrade each worker → uncordon — and say why each step sits where it does.
4. State what `cordon`, `drain`, `uncordon`, and `taint` each change on the Node object, and the three taint effects (`NoSchedule`/`NoExecute`/`PreferNoSchedule`).
5. Explain the Eviction-API/PDB interaction that makes a drain block, and diagnose a stuck drain with `kubectl get pdb -A` (ALLOWED DISRUPTIONS) instead of reaching for `--force`.
6. Merge two kubeconfigs with `KUBECONFIG` + `config view --flatten`, switch context, and state the one command you run before any destructive action.
7. Describe the two-leg backup strategy (etcd snapshot for state, GitOps for intent) and what each one does and does not recover.

➡ Next up: **Repository Management** — now that you can run a cluster across its lifetime, we handle the artifacts that feed it: container registries, Helm charts, and the GitOps repo that is your cluster's real source of truth.
