# The CKA / CKAD / CKS Roadmap & kubectl Speed Drills

> **Module 01 · Course 04** — The CNCF certs aren't knowledge quizzes; they're *performance* exams. You get a live terminal, a stopwatch, and tasks that each want a working object in the cluster. People who already run Kubernetes at work still fail them — not because they don't know the concepts, but because they type too slowly, hunt for YAML field names, and burn minutes they didn't have. This module fixes the speed problem and lays out a sane order to take the three exams.

You run Kubernetes in production, so none of the *concepts* here will be new. What's new is the constraint: **~5–8 minutes per task, no Stack Overflow, one browser tab of docs, and a cluster you must mutate correctly on the first try.** Treat this module as the muscle-memory layer you bolt on top of what you already know.

---

## The three exams at a glance

All three are from the Linux Foundation / CNCF, run in a remote-proctored browser terminal (PSI), scored on *cluster state* not on how you got there, and are **performance-based** — you do real tasks, no multiple choice.

| | **CKA** | **CKAD** | **CKS** |
|---|---|---|---|
| Full name | Certified Kubernetes **Administrator** | Certified Kubernetes **Application Developer** | Certified Kubernetes **Security Specialist** |
| Duration | 2 hours | 2 hours | 2 hours |
| Tasks | ~15–20 | ~15–20 | ~15–16 |
| Pass mark | 66% | 66% | 67% |
| Perspective | You *operate* the cluster | You *ship apps onto* a cluster | You *attack & harden* the cluster |
| Prerequisite | none | none | **valid CKA required to sit it** |
| Allowed docs | kubernetes.io/docs, /blog, kubectl ref | same | same **+ Trivy, Falco, AppArmor, Sysdig docs** |

> **The one rule everyone forgets:** you may keep **one** extra browser tab open on the allowed docs domains. Bookmark the exact deep-links you need (see the end of this module) *before* exam day. Fumbling the docs search is a silent time sink.

### Domains & weightings (what the score is made of)

**CKA** — operator's exam. The weightings shifted in the 2025 curriculum toward cluster-day-2 work:

```
Cluster Architecture, Installation & Config ......... 25%
Workloads & Scheduling .............................. 15%
Services & Networking ............................... 20%
Storage ............................................. 10%
Troubleshooting ..................................... 30%   <- the biggest bucket
```

Troubleshooting is the largest slice: broken kubelets, failing control-plane components, misconfigured CNI, pods stuck Pending. You fix live clusters against the clock.

**CKAD** — developer's exam. Breadth over depth, lots of small object-authoring tasks:

```
Application Design & Build .......................... 20%
Application Deployment .............................. 20%
Application Observability & Maintenance ............. 15%
Application Environment, Config & Security .......... 25%
Services & Networking ............................... 20%
```

This is the exam the imperative generators below win outright — most tasks are "create a Deployment/Job/CronJob/ConfigMap/Secret with these properties," and typing YAML by hand is how you run out of time.

**CKS** — security specialist. Assumes you already operate the cluster (hence the CKA gate):

```
Cluster Setup ....................................... 15%
Cluster Hardening ................................... 15%
System Hardening .................................... 10%
Minimize Microservice Vulnerabilities ............... 20%
Supply Chain Security ............................... 20%
Monitoring, Logging & Runtime Security .............. 20%
```

CKS adds tools you won't have touched in CKA/CKAD: **Trivy** (image scanning), **Falco** (runtime detection), **AppArmor/seccomp** profiles, **gVisor/runtime classes**, admission control (OPA/Kyverno-style), and `kube-bench` CIS benchmarks.

### What actually differs between them

```
        CKAD                 CKA                    CKS
   ┌──────────────┐    ┌──────────────┐      ┌──────────────┐
   │ ship apps    │    │ run clusters │      │ break & harden│
   │ onto a       │ -> │ fix control  │  ->  │ what CKA runs │
   │ working      │    │ plane, nodes,│      │ (needs CKA    │
   │ cluster      │    │ networking   │      │  first)       │
   └──────────────┘    └──────────────┘      └──────────────┘
    objects, probes,    etcd backup/restore,   image scan, RBAC
    multi-container      kubeadm upgrades,      lockdown, network
    pods, Jobs, config   static pods, CNI,      policy default-deny,
    resource limits      troubleshooting        seccomp/AppArmor,
                                                 Falco rules, Trivy
```

- **CKAD never touches the control plane.** You're given a healthy cluster and asked to put correct workloads on it. No etcd, no kubeadm, no node repair.
- **CKA is the control plane.** `etcdctl snapshot save/restore`, `kubeadm upgrade`, static pod manifests in `/etc/kubernetes/manifests`, fixing a kubelet that won't start, drain/cordon, CNI troubleshooting.
- **CKS is adversarial.** It assumes CKA-level operation and adds: given this running cluster, *reduce its attack surface* — default-deny NetworkPolicies, non-root/read-only-rootfs pods, seccomp profiles, RBAC that doesn't leak, scan images for CVEs, catch a running exploit with Falco.

### A sensible order to take them

```
   CKAD  ──►  CKA  ──►  CKS
  (warm-up)  (core)   (requires CKA)
```

1. **CKAD first** (if you're new to the exam *format*). It's the gentlest introduction to the timed-terminal experience, it's almost pure imperative-generator speed, and it has no prerequisites. For an SRE/SDE who already deploys apps, it's the fastest win and builds exam confidence.
2. **CKA second.** It's the deepest and most respected of the three for ops roles, and — critically — it's a **hard prerequisite for CKS**. You cannot register to sit CKS without an active CKA.
3. **CKS last.** It layers security on top of CKA-level operation. Do it while CKA material is still fresh; the two share a lot of cluster-setup ground.

> If your job is already ops/SRE (yours is — LGTM pipeline, K8s, ArgoCD), you *can* go CKA → CKS and skip CKAD entirely. CKAD is optional polish on a CV that already has CKA. The one ordering you can't change: **CKS requires a passing CKA on record.**

---

## Imperative generators — the single biggest time-saver

Hand-writing YAML in a timed exam is how you lose. Every create-shaped task starts from a generator, and `--dry-run=client -o yaml` turns any generator into a YAML skeleton you edit instead of author. Set this up front:

```bash
export do='--dry-run=client -o yaml'   # "dry output"
export now='--force --grace-period=0'  # "delete now"
```

Then the whole family (everything prints YAML you redirect to a file and tweak):

```bash
# Pods
kubectl run nginx --image=nginx:1.27-alpine $do > pod.yaml
kubectl run tmp --image=busybox:1.36 --restart=Never -it --rm -- sh   # throwaway debug pod
kubectl run nginx --image=nginx:1.27-alpine --port=80 \
  --env=TIER=web --labels=app=web $do

# Deployments
kubectl create deploy web --image=nginx:1.27-alpine --replicas=3 $do > deploy.yaml

# Services (two routes — pick the one the task wants)
kubectl create svc clusterip web --tcp=80:80 $do                  # standalone svc
kubectl expose deploy web --port=80 --target-port=80 $do          # svc wired to a deploy's selector
kubectl expose deploy web --port=80 --type=NodePort $do

# ConfigMaps & Secrets
kubectl create cm app-cfg --from-literal=LOG_LEVEL=debug --from-file=app.properties $do
kubectl create secret generic app-sec --from-literal=TOKEN=s3cr3t $do
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com --docker-username=u --docker-password=p $do

# Jobs & CronJobs
kubectl create job pi --image=perl:5.40 $do -- perl -Mbignum=bpi -wle 'print bpi(200)'
kubectl create cronjob backup --image=busybox:1.36 --schedule="*/5 * * * *" $do -- sh -c 'date'

# RBAC (CKA/CKS bread-and-butter)
kubectl create role dev --verb=get,list,watch --resource=pods $do
kubectl create rolebinding dev-bind --role=dev --serviceaccount=default:builder $do
kubectl create clusterrole reader --verb=get,list --resource=nodes $do
kubectl create serviceaccount builder $do
```

> **`expose` vs `create svc`:** `kubectl expose` reads the selector off the target object, so the Service actually routes. `kubectl create svc` makes a bare Service with a default selector you then have to fix. In the exam, prefer `expose` when a workload already exists — it wires the selector for free. The verifier challenge that follows this module checks exactly that: a Service that *selects* the Deployment, not just one that exists.

A few generator gotchas that bite under time pressure:

- `kubectl run` only makes a **Pod** by default now (the old `--generator` deployment behavior is gone). Use `kubectl create deploy` for Deployments.
- Everything after `--` on a `create job`/`run` is the container **command/args**, not kubectl flags — order matters.
- `create deploy --replicas=N` works, but there's no `--replicas` on `kubectl run` (it's a Pod). Scale a Deployment with `kubectl scale deploy web --replicas=5`.
- Generators can't express everything (probes, volumes, securityContext, affinity). Generate the skeleton, then edit the file — that's the workflow, not "generate the final object."

---

## The alias / export speed setup (type this in the first 60 seconds)

Before you touch task 1, paste this block. It pays for itself within two tasks:

```bash
alias k=kubectl
export do='--dry-run=client -o yaml'
export now='--force --grace-period=0'
source <(kubectl completion bash)
complete -o default -F __start_kubectl k
```

And set a default namespace per task so you stop typing `-n` on every command:

```bash
kubectl config set-context --current --namespace=dojo-exam
```

> **Vim speed matters too.** The exam terminal is vim. Put this in `~/.vimrc` on the exam node at the start:
> ```
> set ts=2 sw=2 et ai nu
> ```
> Two-space, expand-tabs, autoindent — YAML is whitespace-sensitive and a stray tab fails `kubectl apply` with a maddening error. `:set paste` before pasting blocks so autoindent doesn't mangle them.

---

## `kubectl explain` — your offline API reference

The allowed docs tab is slow to search. For "what's the exact field name / nesting," `explain` is faster and always right for the server version you're on:

```bash
kubectl explain deployment.spec.strategy.rollingUpdate
kubectl explain pod.spec.containers.securityContext --recursive
kubectl explain cronjob.spec.jobTemplate.spec.template.spec --recursive | less
kubectl explain networkpolicy.spec --recursive        # CKS
```

`--recursive` dumps the whole valid subtree with no descriptions — perfect for "is it `readOnlyRootFilesystem` or `readonlyRootFS`?" without leaving the terminal. This is how you avoid the single most common YAML failure: a field name that's *almost* right and silently ignored or rejected.

---

## Time-boxing & flagging — the exam meta-game

The score is cluster state, so **cheap points first** is the whole strategy:

```
   ┌─────────────────────────────────────────────────────────┐
   │ 1. Read the weight next to each task (e.g. "Weight: 4%"). │
   │ 2. First pass: do every task you can finish in < 3 min.  │
   │ 3. Flag anything that stalls you > 1 min — move on NOW.  │
   │ 4. Second pass: return to flagged tasks with time left.  │
   │ 5. Never let one hard 7% task eat the three easy 4% ones. │
   └─────────────────────────────────────────────────────────┘
```

Concrete rules that save exams:

- **Context switch is mandatory.** Almost every task starts with a given line like `kubectl config use-context cluster-2`. If you skip it you'll do perfect work *in the wrong cluster* and score zero. Run it every single time — it's the number-one avoidable failure.
- **Flag, don't fight.** The exam UI has a notepad/flag. If a task isn't moving in ~60–90 seconds, flag it and go. A 4% task you finish beats a 7% task you half-finish for 0.
- **Verify as you go.** After each create/edit, one quick `kubectl get`/`describe` to confirm the object is actually in the desired state. Re-reading the question after you *think* you're done catches the "it wanted 3 replicas, I made 2" misses.
- **Budget math:** ~2 hours / ~17 tasks ≈ **7 minutes each**. Most generator tasks should take 2–3, buying you time for the 2–3 genuinely hard troubleshooting tasks.
- **Partial credit is real.** Tasks are often scored per-sub-requirement. Even if you can't finish a task, get the parts you can — a Deployment that's right except for one missing label still scores most of its points.

---

## killer.sh and realistic practice

Your exam registration includes **two sessions of killer.sh** (the CNCF exam simulator) — one per purchased exam, each active for 36 hours once started. Treat them as the real thing:

- killer.sh is **deliberately harder than the real exam** (more tasks, nastier edge cases). If you can clear ~70%+ there under time, the real exam feels calmer. Don't panic at a low first score.
- Start a session **only when you can commit 2 focused hours**, then spend the remaining 36 hours of access studying the detailed solutions — that review is where most of the learning is.
- Practice on a throwaway cluster that mirrors the exam: multi-node, your aliases, vim, one docs tab. Your KUBE-DOJO `kind-dojo` cluster is ideal for the CKAD-style object tasks; add a `kubeadm`-built VM cluster when you drill CKA control-plane repair.
- **Bookmark the deep-links** you'll actually paste from on the allowed domains before exam day: a Pod with probes, a NetworkPolicy, a PersistentVolume/PVC pair, an RBAC Role+Binding, a securityContext block. You're allowed the docs — you're not allowed to waste four minutes finding the page.

> **Reality check on difficulty:** none of the three exams is conceptually hard for someone who ships Kubernetes daily. They're *time* exams. The candidates who fail almost always knew the answer — they just couldn't produce a correct object fast enough. Speed is a trainable skill, and the drills in this course are that training.

---

## Checkpoint

You're ready for the imperative drills when you can, without looking anything up:

1. Name all three exams, their duration, pass mark, and which one requires another as a prerequisite.
2. State which domain is the heaviest on CKA (troubleshooting, 30%) and what CKS adds that CKA/CKAD don't test (Trivy, Falco, seccomp/AppArmor, supply-chain).
3. Generate — in one line each — a 3-replica Deployment, a ClusterIP Service wired to it, a ConfigMap, a Secret, a Job, and a CronJob, all with `--dry-run=client -o yaml`.
4. Explain why `kubectl expose deploy ...` beats `kubectl create svc ...` when the Deployment already exists.
5. Recite the time-boxing loop: cheap points first, flag anything over ~90s, always run the `use-context` line, verify with `get`/`describe` before moving on.

➡ Next up: the **Imperative Speed Run** challenge — a timed, CKAD-style task. Create a Deployment and expose it with a Service using only imperative commands, inside a 5-minute target, then prove it with the verifier.
