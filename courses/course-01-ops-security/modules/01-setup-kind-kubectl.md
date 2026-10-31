# Setting Up Your Dojo — kind + kubectl Mastery

> **Module 01 · Course 01** — Before you can break or defend a cluster, you need one you can throw away and rebuild in 60 seconds. That's `kind`. This module gets your lab running and sharpens the one tool you'll live inside for the rest of this course: `kubectl`.

You already run Kubernetes at work, so this is deliberately fast on "what is a pod" and slow on the things that separate someone who *uses* `kubectl` from someone who *wields* it.

---

## Why `kind` (and not minikube)

`kind` = **K**ubernetes **IN** **D**ocker. Every node in your cluster is a Docker **container** running a full kubelet + container runtime, instead of a VM.

```
┌──────────────────────── your Mac (Docker Desktop) ────────────────────────┐
│                                                                            │
│   ┌─ container ─────────┐   ┌─ container ──┐   ┌─ container ──┐            │
│   │  dojo-control-plane │   │ dojo-worker  │   │ dojo-worker2 │            │
│   │  api-server, etcd,  │   │   kubelet    │   │   kubelet    │            │
│   │  scheduler, kubelet │   │  + your pods │   │  + your pods │            │
│   └─────────────────────┘   └──────────────┘   └──────────────┘           │
│          ▲ all three are just `docker ps` entries                         │
└────────────────────────────────────────────────────────────────────────────┘
```

Consequences worth internalizing:

- **Cheap & fast.** No VM to boot. A 3-node cluster uses ~1–2 GB RAM — which is why it fits your 8 GB Mac Mini where minikube's VM would struggle.
- **Ephemeral by design.** `kind delete cluster` and recreate — the whole point of a dojo. Never be precious about the cluster.
- **Node = container** means `docker exec` into a node is a legitimate debugging (and, later, *attack*) technique.
- **Images don't pull from your local Docker automatically** — you must `kind load docker-image <img>` to make a locally-built image available to the cluster. This trips up everyone once.

> **One shared kernel.** Every kind "node" is a container on *your* host kernel. There is no per-node VM boundary, so a `sysctl`, a kernel module, or a cgroup limit is shared host-wide. That's great for speed and realism, and it's exactly why a container escape in Course 03 lands you on the Mac, not in a throwaway VM.

---

## Bring the cluster up

From the `kube-dojo` root:

```bash
# one-time: install kind if you don't have it
bash labs/bootstrap/install-kind.sh

# make sure Docker Desktop is running first, then:
bash labs/bootstrap/create-cluster.sh
```

That script creates a **1 control-plane + 2 worker** cluster named `dojo` and points your kubeconfig at it. Verify:

```bash
kubectl config current-context      # -> kind-dojo
kubectl get nodes -o wide
```

You should see three `Ready` nodes. If `create-cluster.sh` complains about Docker, run `open -a Docker`, wait for the whale icon to settle, and retry.

> **kubeconfig mental model:** a kubeconfig is three lists — `clusters` (where), `users` (who/how to auth), and `contexts` (a named pairing of a cluster + user + default namespace). `kubectl config get-contexts` shows them; the `*` is your current one. Switching clusters is just switching context.

```bash
kubectl config get-contexts
kubectl config use-context kind-dojo
kubectl config set-context --current --namespace=default   # change default ns
```

> **Docker Desktop memory matters on 8 GB.** kind nodes inherit the Docker VM's memory ceiling (Docker Desktop → Settings → Resources). A 3-node cluster plus the LGTM-style add-ons you'll install later wants **at least 4 GB** allocated to Docker. Set it too low and nodes come up `Ready` but pods start getting OOM-killed under load — see Debugging below.

---

## kubectl: from "using" to "wielding"

### 1. Imperative vs declarative — know when to use which

| Style | Command | Use it for |
|-------|---------|-----------|
| Imperative | `kubectl create deploy web --image=nginx` | Throwaway tests, exam speed, generating YAML |
| Imperative-with-edit | `kubectl edit deploy web` | Quick live surgery (never in prod gitops) |
| Declarative | `kubectl apply -f web.yaml` | Everything real — it's idempotent and diff-able |

The pro move is using imperative commands to *generate* declarative YAML:

```bash
kubectl create deploy web --image=nginx:1.27-alpine \
  --dry-run=client -o yaml > web.yaml
```

`--dry-run=client` means "don't touch the cluster, just render what you'd send." This is the single biggest `kubectl` speed-up for both real work and the CKAD exam.

### 2. `-o` output formats — stop reading walls of text

```bash
kubectl get pods -o wide                         # +node, +IP
kubectl get pod web-xxx -o yaml                  # the full object as stored
kubectl get pods -o name                         # just pod/names (scriptable)
kubectl get pods -o jsonpath='{.items[*].spec.nodeName}'   # surgical extraction
kubectl get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName
```

`jsonpath` is worth 20 minutes of your life — it's how you (and every verifier script in this course) pull one exact field out of an object. Example you'll reuse constantly:

```bash
# decode a secret value in one line
kubectl get secret app-config -o jsonpath='{.data.FLAG}' | base64 -d
```

### 3. `explain` — the offline API reference

```bash
kubectl explain deployment.spec.strategy.rollingUpdate
kubectl explain pod.spec.containers.readinessProbe --recursive
```

No more guessing field names or tab-switching to the docs. `--recursive` dumps the whole subtree of valid fields.

### 4. The debugging quartet

When something is wrong, in this order:

```bash
kubectl describe pod <name>     # events at the bottom tell you WHY (ImagePullBackOff, etc.)
kubectl logs <name>             # app stdout/stderr
kubectl logs <name> --previous  # logs from the crashed container, pre-restart
kubectl get events --sort-by=.lastTimestamp   # cluster-wide recent history
```

`describe` → `logs` → `events` resolves the large majority of real incidents. Add these power tools:

```bash
kubectl exec -it <pod> -- sh                       # shell into a running container
kubectl debug -it <pod> --image=busybox --target=<container>   # ephemeral debug container
kubectl run tmp --rm -it --image=nicolaka/netshoot -- bash     # throwaway network debug pod
```

`netshoot` is your Swiss-army knife for DNS/connectivity debugging inside the cluster network — remember it.

### 5. Speed aliases (set these now)

```bash
alias k=kubectl
export do='--dry-run=client -o yaml'   # k create deploy x --image=nginx $do
export now='--force --grace-period=0'  # k delete pod x $now
source <(kubectl completion bash)      # or zsh
complete -o default -F __start_kubectl k
```

---

## Debugging kind bring-up & kubectl context

Most "my dojo is broken" moments are one of five things. Diagnose in this order — cheapest signal first. The golden rule with kind: **when `kubectl` is confused, drop one level down to `docker`**, because every node is just a container.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `kubectl get nodes` shows a node `NotReady` | CNI not up yet, or kubelet starved (Docker low on RAM) | Wait 30–60s; if it persists, check kubelet logs in the node and raise Docker memory (see below) |
| Every pod `Pending`, `describe` says `FailedScheduling: ... Insufficient memory/cpu` | Docker VM memory ceiling too low; scheduler can't fit requests | Raise Docker Desktop memory to ≥4 GB, or lower pod `requests` |
| Pods `OOMKilled` / `CrashLoopBackOff` with exit code 137 | Container hit its memory `limit`, or the whole Docker VM is OOM | Raise the limit, or give Docker more RAM; confirm with `docker stats` |
| `kubectl` hangs or `connection refused` / `was refused - did you specify the right host or port?` | Wrong context, cluster deleted, or Docker not running | `kubectl config current-context`; `docker ps`; `open -a Docker` |
| Commands land on the *wrong* cluster silently | `current-context` isn't `kind-dojo` (e.g. a work cluster is active) | `kubectl config use-context kind-dojo` |
| Pod stuck `ErrImagePull` / `ImagePullBackOff` for a *local* image | You built it on the host; kind nodes never saw it | `kind load docker-image <img> --name dojo` + `imagePullPolicy: IfNotPresent` |
| `error: You must be logged in to the server (Unauthorized)` | Stale client cert in kubeconfig (cluster was recreated under you) | Re-export: `kind export kubeconfig --name dojo` |

### Diagnose each — the exact commands

**Node `NotReady`.** Ask the node why. kind's `kubelet` runs as a systemd unit *inside* the node container:

```bash
kubectl describe node dojo-worker | sed -n '/Conditions:/,/Addresses:/p'
docker exec dojo-control-plane crictl ps -a          # are the control-plane containers up?
docker exec dojo-control-plane journalctl -u kubelet --no-pager | tail -40
```

If the node never goes `Ready`, the CNI pods are the usual suspect — kind ships `kindnet`:

```bash
kubectl -n kube-system get pods -o wide | grep -E 'kindnet|coredns'
```

**Docker OOM / exit 137.** The exit code is the tell: `137 = 128 + 9 (SIGKILL)`, and when the killer is the kernel OOM reaper, `describe` says `OOMKilled`.

```bash
kubectl get pod <name> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
# -> OOMKilled
docker stats --no-stream                             # per-node-container live mem use
docker exec dojo-control-plane sh -c 'cat /proc/meminfo | head -3'
```

If `docker stats` shows a node pinned near its limit, the fix is Docker memory, not the manifest.

**Context confusion.** This is the most dangerous one because nothing errors — your command just runs somewhere you didn't mean:

```bash
kubectl config current-context                       # the ONE command to run before anything scary
kubectl config get-contexts                          # the * marks active
kubectl cluster-info --context kind-dojo             # pin the context explicitly when unsure
```

Make `kubectl config current-context` reflexive before any `delete`, `scale`, or `apply`. On a shared laptop it is the difference between nuking your dojo and nuking something that pages you at work.

**Image not found because not loaded.** Confirm what the *node* actually has, not what your host has:

```bash
docker build -t myapp:dev .
docker exec dojo-control-plane crictl images | grep myapp   # empty = never loaded
kind load docker-image myapp:dev --name dojo
docker exec dojo-control-plane crictl images | grep myapp   # now present on every node
```

Remember: `kind load` copies into **every** node's store, so after a `kind create` you must re-load — a fresh cluster has an empty image store.

**Auth / `Unauthorized` after a rebuild.** When you `kind delete` + `kind create` with the same name, the old kubeconfig entry still points at the dead cluster's CA. Re-export it:

```bash
kind get clusters                                    # is 'dojo' actually there?
kind export kubeconfig --name dojo                   # rewrites ~/.kube/config for this cluster
kubectl config current-context && kubectl get ns     # should work now
```

> **War story.** At SAP I lost 40 minutes to a "flaky" ingress test in CI. Logs were clean, the Deployment was healthy, but every curl 404'd. The build container had **two** kubeconfigs on its `KUBECONFIG` path and `current-context` had silently resolved to a *leftover* kind cluster from a previous job on the same runner — so my `kubectl apply` was landing on a cluster my test never queried. The fix was one line: assert `kubectl config current-context` equals the expected context as the first step of the job and `exit 1` otherwise. Every setup script in this dojo warns on a context mismatch for exactly this reason. Context is state, and unasserted state is a bug waiting for a deadline.

---

## Security note: what a kind cluster gives an attacker

Because kind runs nodes as containers on your host, a few things are *already* true that mirror real-world risk:

- `kubectl config view --raw` exposes the admin client cert/key — in this lab that's you, but in production an exposed kubeconfig is game over.
- `docker exec -it dojo-control-plane bash` drops you onto the "node" with root — the same outcome an attacker seeks via a container escape. We'll do a real escape in Course 03.
- etcd lives in the control-plane container. Everything — including every Secret, base64-encoded not encrypted — is in there. You'll extract a secret the "legit" way in this course's first discovery challenge, and the *attacker* way later.

Keep that framing: **every ops primitive you learn is also an attack surface.** That's the whole point of the balanced track.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Create and tear down the `dojo` cluster.
2. Generate a Deployment's YAML with `--dry-run=client -o yaml`.
3. Pull a single field out of any object with `-o jsonpath`.
4. Decode a Secret value in one piped command.
5. Explain, in one sentence, why "node = container" matters for both debugging and attacking.
6. Diagnose a `NotReady` node by reading kubelet logs *inside* the node container with `docker exec`.
7. Tell `OOMKilled` from any other crash by reading the exit code (137) and `lastState.terminated.reason`.
8. State the one command you run before any destructive `kubectl`, and why context confusion is more dangerous than an outright error.
9. Recover from `Unauthorized` after recreating a cluster with `kind export kubeconfig`.

➡ Next up: the **Make It Survive** challenge — you'll take a fragile single-replica Deployment and make it genuinely production-resilient, then prove it with a verifier.
