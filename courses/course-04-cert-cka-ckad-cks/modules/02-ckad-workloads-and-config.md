# CKAD: Workloads & Configuration

> **Module 02 · Course 04** — This is the heart of the CKAD, and the part of the exam where raw speed converts directly into points. Almost every CKAD task reduces to *"put a correctly-shaped workload on a healthy cluster"* — a Deployment with the right probes, a Job with the right completion semantics, a Pod with an init container, a container wired to a ConfigMap and a Secret with exactly the right keys. None of it is conceptually hard for someone who ships to Kubernetes daily. All of it is a race between you and the clock.

You already write Deployment manifests at work. What this module trains is the *exam dialect* of that skill: generate a skeleton in one line, edit the three fields the task actually cares about, apply, verify, move on — in under three minutes, without opening the docs. We go field-by-field through the objects CKAD loves, show the imperative generator for each, and then spend real time on the failure modes that quietly cost people the exam.

---

## The CKAD workload objects, ranked by how often they appear

```
   appears-a-lot  ┌─────────────────────────────────────────────┐
         ▲        │ Deployment      probes, env, resources       │
         │        │ Pod (raw)       init/sidecar, volumes, SC     │
         │        │ ConfigMap       env + volume wiring           │
         │        │ Secret          generic / docker-registry     │
         │        │ Job             completions, parallelism      │
         │        │ CronJob         schedule, concurrencyPolicy   │
         ▼        │ Service         expose a Deployment (mod 01)  │
   appears-less   └─────────────────────────────────────────────┘
```

The exam is breadth, not depth: many small tasks each worth a few percent. The winning strategy is to never *author* YAML from a blank file. Every object below has a generator that gets you 80% of the way, and you edit the last 20% in vim.

Set the speed harness first (from Module 01, repeated because it earns its keep):

```bash
alias k=kubectl
export do='--dry-run=client -o yaml'
export now='--force --grace-period=0'
source <(kubectl completion bash)
complete -o default -F __start_kubectl k
kubectl config set-context --current --namespace=dojo-ckad
```

---

## Deployments — the field checklist

A CKAD Deployment task names a handful of properties and expects *all* of them present. The generator gives you the shell:

```bash
kubectl create deploy web --image=nginx:1.27-alpine --replicas=3 $do > web.yaml
```

Then you add, by hand, whatever the task asks for. The fields that show up again and again, and where they live:

| Task says… | Field (under `spec.template.spec.containers[0]` unless noted) |
|---|---|
| "container listens on 8080" | `ports: [{containerPort: 8080}]` |
| "set env var `TIER=web`" | `env: [{name: TIER, value: "web"}]` |
| "env from a ConfigMap/Secret" | `envFrom: [{configMapRef: {name: …}}]` |
| "CPU request 100m, limit 250m" | `resources.requests.cpu` / `resources.limits.cpu` |
| "readiness on `/healthz:8080`" | `readinessProbe.httpGet` |
| "run as non-root, uid 1000" | `securityContext.runAsNonRoot: true`, `runAsUser: 1000` |
| "3 replicas, never drop below 3" | `spec.replicas` + `spec.strategy.rollingUpdate.maxUnavailable: 0` |
| "mount config at `/etc/app`" | `volumeMounts` + `spec.template.spec.volumes` |

The reflex you want: read the task, open the file, and for each named property run `kubectl explain` *only if* you can't recall the exact nesting:

```bash
kubectl explain deployment.spec.template.spec.containers.readinessProbe --recursive
kubectl explain deployment.spec.strategy.rollingUpdate
```

### Edit-in-place verbs you should know cold

Half the Deployment tasks are mutations of an object that already exists. Imperative edits are faster than regenerating YAML:

```bash
kubectl scale deploy web --replicas=5
kubectl set image deploy/web web=nginx:1.27          # change just the image, triggers a rollout
kubectl set env deploy/web LOG_LEVEL=debug           # add/overwrite an env var
kubectl set resources deploy/web --requests=cpu=100m,memory=64Mi --limits=cpu=250m,memory=128Mi
kubectl rollout status deploy/web                     # wait for the rollout to settle
kubectl rollout undo deploy/web                       # roll back to the previous ReplicaSet
kubectl rollout history deploy/web
```

> **`set image` vs editing the file:** `kubectl set image` is the single fastest way to satisfy a "update the image to X" task, and it records a rollout you can `undo`. Reach for `kubectl edit` only when the change is structural (adding a probe, a volume) — and remember `edit` opens vim, so `:set paste` before you paste a block.

---

## Jobs & CronJobs — the completion semantics people get wrong

Jobs are where CKAD punishes imprecision. The three knobs that define a Job's behaviour:

| Field | Meaning | Default |
|---|---|---|
| `completions` | how many pods must succeed for the Job to be complete | 1 |
| `parallelism` | how many pods run at once | 1 |
| `backoffLimit` | retries before the Job is marked Failed | 6 |
| `activeDeadlineSeconds` | wall-clock cap; Job fails if it runs longer | none |
| `ttlSecondsAfterFinished` | auto-delete the Job object N seconds after it finishes | none |

```bash
kubectl create job pi --image=perl:5.40 $do -- perl -Mbignum=bpi -wle 'print bpi(200)' > job.yaml
```

A task like *"run this to completion 5 times, 2 at a time, give up after 4 failures"* is `completions: 5`, `parallelism: 2`, `backoffLimit: 4` — the generator won't set those, so you edit them in. The small ASCII picture of what those two numbers do:

```
  completions: 5, parallelism: 2
  time ──►
  pod1 [==done==]        pod4 [==done==]
  pod2 [==done==] pod3 [==done==] pod5 [==done==]
         ▲ at most 2 running at any instant, 5 successes total
```

**CronJob** wraps a Job template on a schedule. The fields that trip people:

```bash
kubectl create cronjob backup --image=busybox:1.36 --schedule="*/5 * * * *" $do -- sh -c 'date' > cron.yaml
```

| Field | Why it matters on the exam |
|---|---|
| `schedule` | standard 5-field cron; `*/5 * * * *` = every 5 min |
| `concurrencyPolicy` | `Allow` (default) / `Forbid` / `Replace` — "don't let runs overlap" = `Forbid` |
| `startingDeadlineSeconds` | if a run is missed (controller down), how late it may still start |
| `successfulJobsHistoryLimit` | how many finished Jobs to keep (default 3) |
| `suspend: true` | pause the schedule without deleting it |

> **The restartPolicy gotcha.** Both `Job` and `CronJob` pod templates **must** set `restartPolicy: Never` or `OnFailure` — the default `Always` is *invalid* for a Job and the API rejects it. The generator sets this correctly; if you hand-write the template, this is the error you'll hit first (`spec.template.spec.restartPolicy: Unsupported value: "Always"`).

---

## Multi-container pods — sidecars and init containers

CKAD loves multi-container patterns because they test whether you understand pod lifecycle, not just object shapes. Three containers share a pod's network (same `localhost`, same IP) and can share volumes.

```
┌──────────────── Pod ────────────────┐
│  initContainers (run to completion,  │
│  in order, BEFORE app starts)        │
│   └─ init-schema  [exit 0] ──┐       │
│                              ▼       │
│  containers (run concurrently):      │
│   ├─ app      :8080  ──┐              │
│   └─ sidecar  (log shipper)          │
│                        │             │
│  shared: localhost, emptyDir volume  │
└──────────────────────────────────────┘
```

### Init containers — ordered, blocking, run-once

Init containers run **sequentially, to completion, before** any app container starts. Classic uses: wait for a dependency, run a migration, populate a shared volume.

```yaml
spec:
  initContainers:
    - name: wait-for-db
      image: busybox:1.36
      command: ['sh', '-c', 'until nslookup db.dojo-ckad.svc; do echo waiting; sleep 2; done']
  containers:
    - name: app
      image: nginx:1.27-alpine
```

If an init container never exits 0, the pod sits in `Init:0/1` forever — a very common "my pod won't start" trap (see Debugging below).

### Sidecars — the native kind (1.29+) vs the classic kind

The *classic* sidecar is just a second entry in `containers` that runs for the pod's lifetime (a log shipper, a proxy). The problem: on a **Job**, a plain sidecar that never exits keeps the pod running forever, so the Job never completes.

Kubernetes 1.29 made **native sidecars** GA: an init container with `restartPolicy: Always`. It starts before the app, stays running alongside it, and — crucially — does **not** block Job completion.

```yaml
spec:
  initContainers:
    - name: log-shipper
      image: busybox:1.36
      restartPolicy: Always          # <- this is what makes it a native sidecar
      command: ['sh', '-c', 'tail -F /var/log/app/out.log']
      volumeMounts:
        - {name: logs, mountPath: /var/log/app}
  containers:
    - name: app
      image: nginx:1.27-alpine
      volumeMounts:
        - {name: logs, mountPath: /var/log/app}
  volumes:
    - name: logs
      emptyDir: {}
```

> **Know both, because the exam cluster version decides which the task wants.** On a 1.28-or-older cluster the native-sidecar field is ignored and you use a classic sidecar. On 1.29+, if a Job task says "ship logs with a sidecar and still let the Job finish," the native sidecar is the *only* correct answer. Check the server version first: `kubectl version -o json | grep gitVersion` — don't assume.

---

## Probes — the three kinds and when each fires

Three probe types, three distinct jobs. Confusing them is a classic CKAD miss because a wrong probe choice "works" in the happy path and only bites under failure:

| Probe | Question it answers | Failure action |
|---|---|---|
| `readinessProbe` | "Can this pod take traffic *right now*?" | Remove pod from Service endpoints (no restart) |
| `livenessProbe` | "Is this container wedged and needs a kick?" | Restart the container |
| `startupProbe` | "Has a slow-booting app finished starting?" | Hold off liveness/readiness until it passes |

```
  startupProbe ───(passes once)──► then livenessProbe + readinessProbe take over
       ▲
   use for apps with a long/variable boot so liveness doesn't kill them mid-startup
```

All three support the same three handlers — pick based on what the task describes:

```yaml
readinessProbe:
  httpGet: {path: /healthz, port: 8080}     # HTTP 200-399 = pass
livenessProbe:
  exec: {command: ['cat', '/tmp/ready']}    # exit 0 = pass
startupProbe:
  tcpSocket: {port: 8080}                    # connection opens = pass
  failureThreshold: 30
  periodSeconds: 10                          # => up to 300s to boot before liveness starts
```

The timing fields you must be able to set on sight: `initialDelaySeconds`, `periodSeconds`, `timeoutSeconds`, `successThreshold`, `failureThreshold`.

> **The liveness-probe foot-gun.** A liveness probe that's too aggressive (short `initialDelaySeconds` on a slow app) turns a healthy pod into a `CrashLoopBackOff`: the app hasn't finished booting, liveness fails, kubelet restarts it, repeat forever. If a task says "the app takes ~40s to start," that's a signal to use a `startupProbe`, not to crank `initialDelaySeconds` on liveness.

---

## ConfigMaps & Secrets — the four wiring patterns

Creating them is trivial; the points are in *wiring them into a pod the exact way the task names.* There are four patterns, and the task's wording tells you which:

```bash
kubectl create cm app-cfg --from-literal=LOG_LEVEL=debug --from-file=app.properties $do
kubectl create secret generic app-sec --from-literal=TOKEN=s3cr3t $do
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com --docker-username=u --docker-password=p $do
kubectl create secret tls web-tls --cert=tls.crt --key=tls.key $do
```

| Task wording | Pattern | YAML shape |
|---|---|---|
| "set env var X from key Y" | single env key | `env: [{name: X, valueFrom: {configMapKeyRef: {name: cfg, key: Y}}}]` |
| "inject *all* keys as env" | bulk env | `envFrom: [{configMapRef: {name: cfg}}]` |
| "mount the config as files at /etc/app" | volume mount | `volumes: [{name: c, configMap: {name: cfg}}]` + `volumeMounts` |
| "mount only key Y as file app.conf" | projected / items | `configMap: {name: cfg, items: [{key: Y, path: app.conf}]}` |

```yaml
# "mount the config as files at /etc/app" — the pattern people fumble
spec:
  containers:
    - name: app
      image: nginx:1.27-alpine
      volumeMounts:
        - name: cfg
          mountPath: /etc/app
          readOnly: true
  volumes:
    - name: cfg
      configMap:
        name: app-cfg
```

Two sharp edges worth memorizing:

- **Secret `data` is base64, `stringData` is plaintext.** When you hand-write a Secret, put human-readable values under `stringData` and let the API encode them — far fewer mistakes than base64-ing by hand under time pressure.
- **Env wiring is captured at pod start.** Changing a ConfigMap does **not** update env vars in a running pod — only *volume-mounted* ConfigMaps update live (and even then after a kubelet sync delay). If a task implies "config should update without recreating the pod," that's a volume mount, not `envFrom`.

---

## Resource requests, limits & QoS — the one table to internalize

CKAD tests requests/limits mostly through QoS class and scheduling. The rule is mechanical:

| You set… | QoS class | Consequence |
|---|---|---|
| requests **==** limits, for every resource | **Guaranteed** | last to be OOM-killed under node pressure |
| requests **<** limits (or only one set) | **Burstable** | killed after BestEffort, before Guaranteed |
| nothing | **BestEffort** | first evicted / OOM-killed |

```bash
kubectl get pod web -o jsonpath='{.status.qosClass}{"\n"}'   # confirm what you built
```

> A task that says "this pod must be the last thing evicted under memory pressure" is asking for **Guaranteed** QoS — set requests and limits to *identical* values for both cpu and memory. Not "high limits." Identical requests and limits. That's the only way to land in the Guaranteed class.

---

## The exam-timed workflow for any workload task

The loop you run on every single task, drilled until it's reflex:

```
   ┌──────────────────────────────────────────────────────────┐
   │ 1. use-context line (given in the task) — ALWAYS run it.  │
   │ 2. set default namespace for this task.                   │
   │ 3. generate skeleton with the right generator + $do.      │
   │ 4. edit ONLY the fields the task names (explain if unsure)│
   │ 5. kubectl apply -f obj.yaml                              │
   │ 6. kubectl get / describe — confirm desired state.        │
   │ 7. re-read the task once; did you hit every sub-clause?   │
   └──────────────────────────────────────────────────────────┘
```

Steps 6–7 are where points are saved: partial credit is per-sub-requirement, so a 10-second `describe` that catches "it wanted 3 replicas, I made 2" is worth more than the next task you'd rush into.

---

## Debugging common CKAD traps

These are the pod states that eat exam minutes. The discipline is the same as Module 01: read the *events* at the bottom of `describe` first — they almost always name the cause verbatim.

| Symptom | Likely cause | Fix |
|---|---|---|
| Pod stuck `Pending`, events say `FailedScheduling: Insufficient cpu/memory` | requests larger than any node can fit | lower `resources.requests`, or check `kubectl describe node` allocatable |
| Pod stuck `Pending`, no scheduling event | unbound PVC, or a nodeSelector/affinity nothing matches | `kubectl get pvc`; check `spec.nodeSelector` vs `kubectl get nodes --show-labels` |
| Pod stuck `Init:0/1` (or `Init:0/2`) | an init container never exits 0 (waiting on a dep that isn't there) | `kubectl logs <pod> -c <init-name>` to see what it's waiting on |
| `CreateContainerConfigError` | env/volume references a ConfigMap/Secret **key** that doesn't exist | `kubectl describe pod` names the missing key; fix the key name or create it |
| `ImagePullBackOff` / `ErrImagePull` | wrong image tag, or private registry with no `imagePullSecrets` | fix the tag; add `spec.imagePullSecrets: [{name: regcred}]` |
| `CrashLoopBackOff`, exits fast | app error, OR a too-aggressive liveness probe killing it mid-boot | `kubectl logs <pod> --previous`; relax liveness / add `startupProbe` |
| `CrashLoopBackOff`, exit code 137 | OOMKilled — container hit its memory `limit` | raise `resources.limits.memory`; confirm with `lastState.terminated.reason` |
| Job never completes, pod `Running` forever | a classic sidecar that never exits, or `restartPolicy: Always` | use a **native** sidecar (`initContainers` + `restartPolicy: Always`), set `restartPolicy: OnFailure` |
| ConfigMap change didn't take effect | wired as `envFrom` (captured at start), not a volume | re-create the pod, or mount as a volume for live updates |

### The exact commands, in order

**Always start here — the event log names most causes outright:**

```bash
kubectl describe pod <name> | sed -n '/Events:/,$p'     # just the events block
kubectl get events --sort-by=.lastTimestamp | tail -20  # cluster-wide recent history
```

**Init container stuck — logs of the *init* container specifically:**

```bash
kubectl logs <pod> -c wait-for-db          # -c selects the container by name
kubectl get pod <pod> -o jsonpath='{.status.initContainerStatuses[0].state}{"\n"}'
```

**Missing ConfigMap/Secret key (`CreateContainerConfigError`):**

```bash
kubectl describe pod <name> | grep -A2 -i 'config\|secret\|couldn.t find'
kubectl get cm,secret                                   # does the referenced object even exist?
kubectl get cm app-cfg -o jsonpath='{.data}{"\n"}'      # does it have the key you referenced?
```

**OOMKilled vs app crash — read the exit reason, don't guess:**

```bash
kubectl get pod <name> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
# -> OOMKilled  => it's memory, raise the limit
kubectl logs <name> --previous                          # -> app stack trace => it's the app
```

**Job that won't finish — inspect the controller's view:**

```bash
kubectl get job <name> -o jsonpath='{.status}{"\n"}'    # completions vs succeeded
kubectl describe job <name> | sed -n '/Events:/,$p'
kubectl get pods -l job-name=<name>                     # are pods Running (sidecar?) or Error?
```

> **War story.** Preparing a teammate for CKAD, I watched them lose eight minutes on a "pod won't start" task that was worth 4%. The pod sat in `Init:0/1`. They re-applied the manifest three times, re-typed the image tag, even deleted and recreated the namespace. The events block — which they never scrolled to — said in plain English that the init container was `exec`ing `nslookup db.svc` against a Service that the task hadn't had them create yet. One `kubectl logs <pod> -c wait-for-db` would have shown `waiting… waiting…` in the first fifteen seconds. The lesson that stuck: on *any* stuck pod, your first two keystrokes are `describe` → scroll to Events, and if it's a multi-container pod, `logs -c <name>`. The object is almost never lying to you; you're just not reading the part where it tells you what's wrong.

---

## Checkpoint

You're ready for the workload drills when you can, without looking anything up:

1. Generate — one line each, with `--dry-run=client -o yaml` — a 3-replica Deployment, a Job with `completions: 5`/`parallelism: 2`, a CronJob that won't overlap runs (`concurrencyPolicy: Forbid`), a ConfigMap, a generic Secret, and a docker-registry Secret.
2. State the four ConfigMap/Secret wiring patterns and the task wording that selects each — single env key, bulk `envFrom`, whole-volume mount, single-key `items` mount.
3. Explain the difference between readiness, liveness, and startup probes, and name the one that fixes a slow-booting app being killed in a `CrashLoopBackOff`.
4. Write a native sidecar (init container with `restartPolicy: Always`) and explain why a classic sidecar breaks Job completion while the native one doesn't.
5. Give the three fields that set QoS to **Guaranteed**, and name which QoS class is evicted first under node memory pressure.
6. Diagnose `Init:0/1`, `CreateContainerConfigError`, and exit code 137 — name the one command that distinguishes an OOMKill from an app crash.
7. Recite the per-task loop: use-context, set namespace, generate, edit named fields only, apply, verify with `describe`, re-read the task.

➡ Next up: **Module 03** moves from shipping apps to running the cluster underneath them — kubeadm components, static pods, node drain/upgrade, etcd snapshot/restore, and repairing a broken control plane. That's the CKA's heaviest ground.
