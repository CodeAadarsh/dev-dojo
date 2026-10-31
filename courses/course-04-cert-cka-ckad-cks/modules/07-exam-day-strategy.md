# Exam-Day Strategy & Practice Plan

> **Module 07 · Course 04** — These exams are 2-hour, hands-on, performance-based tests on a real cluster with a browser terminal. They reward *speed and accuracy under time pressure*, not deep theory. You already know Kubernetes; this module is about not leaving marks on the table.

## The three exams at a glance

| | CKAD | CKA | CKS |
|---|------|-----|-----|
| Focus | build & run apps | operate the cluster | secure the cluster |
| Duration | 2h | 2h | 2h |
| Passing | 66% | 66% | 67% |
| Prereq | none | none | **valid CKA** |
| Flavor | workloads, config, probes, Jobs | nodes, etcd, networking, storage, troubleshooting | PSA, NetworkPolicy, runtime, supply chain, audit |

Sensible order: **CKAD → CKA → CKS** (CKAD builds speed, CKA builds operations, CKS requires CKA).

## The speed setup (do this in the first 60 seconds)

```bash
alias k=kubectl
export do='--dry-run=client -o yaml'     # k create deploy x --image=nginx $do > x.yaml
export now='--force --grace-period=0'    # k delete pod x $now
source <(kubectl completion bash); complete -o default -F __start_kubectl k
```

Set the context the question demands (every question tells you):

```bash
kubectl config use-context <given-context>
```

## Imperative generators = your biggest time saver

```bash
k run pod1 --image=nginx:1.27-alpine $do
k create deploy web --image=nginx:1.27-alpine --replicas=3 $do
k create cj cron --image=busybox:1.36 --schedule="*/1 * * * *" -- /bin/sh -c 'date' $do
k create job j --image=busybox:1.36 $do
k create cm app --from-literal=KEY=val $do
k create secret generic s --from-literal=pw=123 $do
k expose deploy web --port=80 $do
k create role r --verb=get,list --resource=pods $do
k create rolebinding rb --role=r --serviceaccount=ns:sa $do
```

Generate the YAML, then edit the 10% the generator can't express (probes, volumes, securityContext). Never hand-write a Deployment from scratch.

## Docs are allowed — use them fast

You may open **one** tab to `kubernetes.io/docs`, `kubernetes.io/blog`, and the project docs for Helm/etc. Bookmark nothing you can generate; bookmark the YAML snippets you *can't* (NetworkPolicy, securityContext, volumeClaimTemplates, Ingress). `kubectl explain <path> --recursive` is faster than the browser for field names.

## Time management

- **~15 questions, weighted.** Do the highest-weight, fastest questions first. The top bar shows each question's %.
- **Flag and skip** anything you can't crack in ~1.5× its fair time. Come back.
- **Verify as you go**: after each task, a quick `kubectl get`/`describe` to confirm it actually applied. Half-done tasks score partial.
- Don't fix a broken thing you created by debugging YAML — delete and regenerate.

## Troubleshooting is a guaranteed CKA category

The method, fast: `describe` (events) → `logs`/`--previous` → `events` → check the control-plane static pods on the node (`/etc/kubernetes/manifests`, `crictl ps`) for CKA cluster-component failures. Common exam breakages: kubelet misconfig, a bad static-pod manifest, a cordoned node, a wrong Service selector, an unbound PVC.

## Debugging your own slowness

| Symptom | Fix |
|---------|-----|
| Hand-writing manifests | use generators + `$do` |
| Hunting field names in the browser | `kubectl explain --recursive` |
| Re-typing long names | completion + `k` alias |
| Running out of time | flag/skip, do high-weight first |
| Tasks "done" but 0 points | you forgot `use-context`, or didn't verify |

> **War story:** strong engineers fail CKAD not on knowledge but on pace — they hand-craft three Deployments and run out of time with five questions untouched. The ones who pass generate everything with `$do`, edit the delta, verify, and move on.

## A 6-week practice plan

1. **Weeks 1-2:** CKAD — grind workloads/config/probes/Jobs. Target: any CKAD task in < 4 min.
2. **Weeks 3-4:** CKA — nodes, etcd backup/restore, networking, storage, troubleshooting. Do timed sets.
3. **Weeks 5-6:** CKS — the hardening checklist (module 06) until the securityContext block is muscle memory.
4. Throughout: **killer.sh** (2 free sessions per exam — harder than the real thing) and every challenge in this dojo under a timer.

## Checkpoint

1. Set up aliases + `$do` + completion in under a minute.
2. Generate a Deployment, Service, CronJob, Role, and RoleBinding imperatively.
3. State the pass marks and prereq for all three exams.
4. Describe your first-5-minutes routine and your skip rule.
5. Run the troubleshooting method on a broken node component.

➡ You've finished the Cert track's guide. Now drill the challenges under a timer.
