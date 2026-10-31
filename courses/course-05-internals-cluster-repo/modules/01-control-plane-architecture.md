# The Control Plane, Up Close

> **Module 01 · Course 05** — You run workloads on Kubernetes every day. Now we open the lid. By the end of this module a `kubectl apply` is no longer magic: you can name every process that touches the request, in order, and you can log into the control-plane "node" and watch those processes as plain containers. This is the difference between someone who files a ticket when the API is slow and someone who runs `etcdctl endpoint status` and knows which member lost quorum.

On `kind`, the entire control plane is one Docker container — `dojo-control-plane`. That is a gift: the components a managed provider hides behind a console are, here, static-pod manifests on a filesystem you can `cat` and processes you can `crictl ps`. We exploit that relentlessly.

---

## The five components, and the one data store

Kubernetes is not one program. It is a handful of independent control loops plus a database, all talking to each other **only** through the API server. Internalize that last part — nothing in Kubernetes talks to etcd directly except the api-server. The scheduler does not write to etcd. The kubelet does not read from etcd. Everything funnels through the api-server's REST surface.

| Component | Process | Job | What breaks if it's down |
|-----------|---------|-----|--------------------------|
| **kube-apiserver** | `kube-apiserver` | The *only* front door. Validates, authorizes, admits, persists. Serves `/api` and `/apis`. | Nothing can be read or changed. Running pods keep running (kubelet has a cache); you just can't observe or mutate anything. |
| **etcd** | `etcd` | The single source of truth. A consistent, watchable key-value store holding every object. | API server can't read/write state. Cluster is frozen. |
| **kube-scheduler** | `kube-scheduler` | Assigns `Pending` pods to nodes by writing `spec.nodeName`. | New pods stay `Pending` forever. Existing pods untouched. |
| **kube-controller-manager** | `kube-controller-manager` | Runs ~40 controllers (Deployment→ReplicaSet→Pod, node lifecycle, endpoints, jobs, …). | Deployments don't create ReplicaSets, dead nodes aren't noticed, Services get no Endpoints. Drift stops being reconciled. |
| **cloud-controller-manager** | `cloud-controller-manager` | Cloud-specific loops: LoadBalancer provisioning, node address/zone labels, route tables. On kind it's **absent** (no cloud). | On a real cloud: `type: LoadBalancer` Services stay `<pending>`, node labels go stale. |

And on **every** node, including the control plane: the **kubelet** (turns PodSpecs into running containers via the CRI) and **kube-proxy** (programs iptables/IPVS for Service VIPs). Those are node agents, not control-plane components, but they're the other half of the story — Module 03 is about them.

```
          ┌────────────────────────────── dojo-control-plane (one container) ──────────────────────────────┐
          │                                                                                                 │
   kubectl│        ┌───────────────┐        watch/list         ┌──────────────┐                            │
   ───────┼───────▶│  kube-apiserver│◀───────────────────────▶ │     etcd     │  (the only writer to disk) │
    (TLS) │        │  authn→authz→  │   read/write via gRPC     │  raft, WAL   │                            │
          │        │  admission→etcd│                           └──────────────┘                            │
          │        └──────┬────┬────┘                                                                        │
          │               ▲    │ watch                                                                       │
          │        watch  │    ▼                                                                             │
          │        ┌──────┴──────┐   ┌─────────────────────────┐   ┌──────────────────────┐                 │
          │        │  scheduler  │   │ controller-manager (~40 │   │ kubelet (this node)  │                 │
          │        │ binds pods  │   │ loops: deploy, node, ep)│   │ static pods + CRI    │                 │
          │        └─────────────┘   └─────────────────────────┘   └──────────────────────┘                 │
          └─────────────────────────────────────────────────────────────────────────────────────────────────┘
                     every arrow is HTTPS to the api-server — NOTHING bypasses it to reach etcd
```

The pattern to carry with you: **the api-server is a dumb-ish REST+watch server over etcd; all the intelligence is in controllers that watch for desired-vs-actual drift and act.** Kubernetes is a pile of reconcile loops wearing a trench coat.

---

## The api-server write path: authn → authz → admission → etcd

This is the sequence every mutating request runs. When something is rejected, the *stage* that rejected it tells you exactly where to look. Memorize the order.

```
request ──▶ [1 TLS/authn] ──▶ [2 authz] ──▶ [3 mutating admission] ──▶ [4 schema validate]
                                                                              │
                        [6 etcd write] ◀── [5 validating admission] ◀─────────┘
                                │
                                ▼
                    200 + watchers notified
```

1. **Authentication** — *who are you?* The api-server checks your client cert, bearer token, or OIDC. Failure → `401 Unauthorized`. (In this lab your kubeconfig carries the admin client cert minted by kubeadm.)
2. **Authorization** — *are you allowed to do this verb on this resource?* RBAC (usually), or Node/ABAC/Webhook. Failure → `403 Forbidden`, and the message names the missing verb/resource/namespace.
3. **Mutating admission** — webhooks and built-in controllers that *change* the object: defaulting, sidecar injection (Istio), `MutatingAdmissionWebhook`. This is where an object sprouts fields you never set.
4. **Schema validation / defaulting** — the object is checked against the OpenAPI schema for its GVK and server-side defaults are filled in.
5. **Validating admission** — webhooks/policies that *accept or reject* but don't mutate: `ValidatingAdmissionWebhook`, Pod Security admission, ResourceQuota, OPA/Gatekeeper, the newer CEL `ValidatingAdmissionPolicy`. Failure → `403` with the policy's message.
6. **etcd write** — serialized (protobuf) and persisted under a key like `/registry/<resource>/<namespace>/<name>`. The write bumps the object's `resourceVersion`, and **every `watch` on that resource is notified** — which is how the scheduler and controllers find out anything happened.

Watch the stages live with audit-style verbosity against the lab api-server:

```bash
# -v=8 prints the HTTP request/response round-trips kubectl makes to the api-server
kubectl -v=8 get pods 2>&1 | grep -E 'GET|round_trippers|Response Status'

# Which admission plugins are actually enabled on this api-server?
docker exec dojo-control-plane grep -- --enable-admission-plugins \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

> **Mental test:** a Deployment you applied has an `imagePullPolicy` set even though you never wrote one. Which stage did that? → Stage 4 (defaulting): a `:latest` tag (or no tag) defaults to `Always`, any other tag defaults to `IfNotPresent`. Knowing *which stage* owns a surprise field is how you stop guessing where it came from.

---

## etcd: the one thing you cannot lose

etcd is a distributed, strongly-consistent key-value store using the **Raft** consensus protocol. Properties that matter operationally:

- **Quorum.** A cluster of `N` members tolerates `(N-1)/2` failures. So 3 members tolerate 1, 5 tolerate 2. **Even numbers buy you nothing** — a 4-member cluster still only tolerates 1 failure but has more ways to fail, which is why you always run 1, 3, or 5. Lose quorum and etcd goes **read-only until a majority is restored** — the whole control plane freezes.
- **Everything is in there.** Every Secret (base64, not encrypted unless you configured encryption-at-rest), every ConfigMap, every object. etcd access = cluster-admin, full stop.
- **It's the backup target.** You never back up "the cluster." You snapshot etcd. Restore etcd and the cluster's entire declared state comes back.

On the lab node etcd itself runs as a static pod. Talk to it directly:

```bash
# etcd runs inside the control-plane container; etcdctl ships with it
docker exec dojo-control-plane sh -c '
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint status --write-out=table'

# Count every key Kubernetes stores, and peek at the namespace of keys
docker exec dojo-control-plane sh -c '
  ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/ --prefix --keys-only | head -30'
```

That `--prefix --keys-only` dump is the moment control-plane internals stop being abstract — you are looking at the literal filesystem of your cluster's intent.

---

## Static pods: how the control plane boots itself

Chicken-and-egg problem: the scheduler and controller-manager are *themselves* pods, but there's no scheduler running yet to schedule them. The answer is **static pods** — pods the **kubelet** runs directly from manifest files on disk, with no api-server or scheduler involved. The kubelet watches a directory (`/etc/kubernetes/manifests`), and anything that appears there it runs, then creates a read-only *mirror pod* in the api-server so you can see it with `kubectl`.

```bash
# The four control-plane static-pod manifests live here
docker exec dojo-control-plane ls -l /etc/kubernetes/manifests
# -> etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml

# See them actually running at the container-runtime level (containerd via crictl)
docker exec dojo-control-plane crictl ps --name kube-apiserver
docker exec dojo-control-plane crictl ps -o wide | grep -E 'etcd|apiserver|scheduler|controller'

# The mirror pods, as the api-server sees them
kubectl -n kube-system get pods -o wide | grep dojo-control-plane
```

Two consequences you will use:

1. **Editing a manifest in `/etc/kubernetes/manifests` restarts that component.** The kubelet detects the file change and recreates the pod. This is how you add an api-server flag (e.g. an audit log, an admission plugin, encryption-at-rest) on a kubeadm cluster — you edit `kube-apiserver.yaml` in place.
2. **You cannot `kubectl delete` a static pod away.** The mirror pod comes right back, because the kubelet owns it, not a controller. To stop it, move or delete the manifest file.

---

## End to end: what a `kubectl apply -f deploy.yaml` actually triggers

Follow a single Deployment of 3 replicas from your terminal to running containers. Every hop is a reconcile loop reacting to a watch event.

```
1. kubectl          POST /apis/apps/v1/namespaces/dojo-trace/deployments  (TLS, your client cert)
2. api-server       authn→authz→admission→validate→WRITE Deployment to etcd; notify watchers
3. deployment ctrl  (watching Deployments) sees new Deployment → CREATES a ReplicaSet in etcd
4. replicaset ctrl  (watching ReplicaSets) sees RS wants 3, has 0 → CREATES 3 Pods (nodeName empty) in etcd
5. scheduler        (watching Pods with empty nodeName) filters+scores nodes → PATCHES spec.nodeName on each Pod
6. kubelet(worker)  (watching Pods bound to its node) sees a Pod assigned → calls CRI to pull image + start containers,
                    sets up the pod sandbox + CNI network, then PATCHES Pod status = Running/Ready
7. endpoints/EPS    (watching Pods + Services) sees Ready pods matching a Service selector → writes EndpointSlice
8. kube-proxy       (watching EndpointSlices) programs iptables so the Service VIP load-balances to the 3 pod IPs
```

Nobody orchestrates this top-down. Each actor only watches the api-server, notices drift between *desired* and *actual*, makes one small change, and writes it back — which becomes the next actor's trigger. Watch the chain unfold in real time:

```bash
kubectl create ns dojo-trace --dry-run=client -o yaml | kubectl apply -f -
# two watchers in separate panes, then apply a deployment:
kubectl get events -n dojo-trace --watch &
kubectl -n dojo-trace create deploy web --image=nginx:1.27-alpine --replicas=3
kubectl -n dojo-trace get deploy,rs,pods -o wide        # Deployment → ReplicaSet → Pods, each owned by the last
kubectl -n dojo-trace get pod -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}'
```

The `ownerReferences` chain (`Pod → ReplicaSet → Deployment`) is that choreography made durable: it's how garbage collection and `kubectl delete deploy` cascade correctly.

---

## Debugging the control plane

When the control plane itself is sick, `kubectl` is often the *thing that's broken*, so you drop to `docker exec`, `crictl`, and the kubelet's own logs. Here's the triage table.

| Symptom | Likely cause | Fix / confirm |
|---------|--------------|---------------|
| `kubectl` hangs then `The connection to the server <host>:6443 was refused` | api-server pod crashed or not listening on :6443 | `docker exec dojo-control-plane crictl ps -a --name kube-apiserver` → if `Exited`, read its logs (below) |
| api-server `CrashLoopBackOff` right after you edited a manifest | typo/bad flag in `kube-apiserver.yaml`, or it can't reach etcd | `docker exec dojo-control-plane crictl logs <apiserver-id>` — the flag parse error is the last line |
| `x509: certificate has expired or is not yet valid` | kubeadm client/serving certs expired (1-year default) | `docker exec dojo-control-plane kubeadm certs check-expiration`; renew with `kubeadm certs renew all` then restart the static pods |
| Everything frozen; api-server logs show `etcdserver: request timed out` / `leader changed` | etcd lost quorum or is wedged | `etcdctl endpoint status`/`endpoint health` on each member; restore quorum or `etcdctl snapshot restore` |
| New pods stuck `Pending`, existing pods fine | scheduler down | `crictl ps --name kube-scheduler`; check `kubectl get events` for *no* scheduling events at all |
| Deployments don't create pods; dead node not marked `NotReady` | controller-manager down | `crictl ps --name kube-controller-manager`; read its logs for leader-election loss |
| `type: LoadBalancer` Service stuck `<pending>` (real cloud) | cloud-controller-manager down/misconfigured | check CCM logs; on kind this is *expected* (no cloud) — use a NodePort or MetalLB instead |

The exact commands you reach for, in order:

```bash
# 1. Is the component even running at the runtime level? (kubectl may be the casualty)
docker exec dojo-control-plane crictl ps -a | grep -E 'apiserver|etcd|scheduler|controller'

# 2. Read a crashed component's logs by container id
APISERVER=$(docker exec dojo-control-plane crictl ps -a --name kube-apiserver -q | head -1)
docker exec dojo-control-plane crictl logs "$APISERVER" 2>&1 | tail -40

# 3. The kubelet's journal — it logs WHY it couldn't start a static pod
docker exec dojo-control-plane journalctl -u kubelet --no-pager | tail -60

# 4. Certificate expiry (the classic "cluster that sat in a drawer for a year")
docker exec dojo-control-plane kubeadm certs check-expiration

# 5. etcd member health and who the leader is
docker exec dojo-control-plane sh -c '
  ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint status --write-out=table'
```

> **War story.** A team ran a 2-node etcd cluster because "2 is more redundant than 1." During a routine AZ maintenance window one member went down. With 2 members, quorum is 2 — losing one dropped them below majority, and etcd went **read-only instantly**. The symptom at the top was baffling: every `kubectl apply` hung for 15s then failed with `etcdserver: request timed out`, but all running pods kept serving traffic (kubelets were happily running from their last-known spec). On-call spent 40 minutes staring at application dashboards that were all green before someone ran `etcdctl endpoint status` and saw one member `unhealthy` and the other refusing writes. The lesson is burned in now: **etcd member count must be 1, 3, or 5 — never even.** The fix was to bring the maintenance node back; the real fix was re-provisioning as a 3-member cluster so one AZ going dark is survivable.

> **War story, the sequel.** A different outage: `kubectl apply` of a new workload mysteriously hung for exactly 30 seconds then returned `Internal error occurred: failed calling webhook "inject.sidecar.io": context deadline exceeded`. Nothing was wrong with the control plane itself. The cause was stage 3/5 of the write path — a **mutating admission webhook** (a sidecar injector) whose backing pod had been evicted. Because its `failurePolicy` was `Fail`, *every* object creation cluster-wide that matched its rules blocked on a webhook that would never answer. Knowing the write-path stages told the responder immediately: "the request reached admission and died there" → `kubectl get mutatingwebhookconfigurations` → found the dead service → scaled its Deployment back up. Admission webhooks are control-plane code you wrote; a broken one is a self-inflicted api-server outage.

---

## Checkpoint

You've got this module when you can, without looking it up:

1. Name the five control-plane components + etcd, and state what breaks when each one dies.
2. Recite the api-server write path (authn → authz → mutating admission → validate → validating admission → etcd) and map a given `403`/surprise-field/hung-apply to the stage that caused it.
3. Explain why nothing but the api-server talks to etcd, and why that makes "Kubernetes is a pile of reconcile loops" accurate.
4. State etcd's quorum math and why member counts are always 1, 3, or 5 — then read `etcdctl endpoint status` on the lab node.
5. Find the static-pod manifests in `/etc/kubernetes/manifests`, list the running components with `crictl ps`, and explain why `kubectl delete` can't remove a static pod.
6. Trace a `kubectl apply` of a 3-replica Deployment through Deployment→ReplicaSet→Pod→schedule→kubelet→EndpointSlice→kube-proxy, naming the watch event that triggers each hop.

➡ Next up: **The Scheduler** — now that you know *who* assigns `spec.nodeName`, we go deep on *how* it chooses, and why your pod is stuck `Pending`.
