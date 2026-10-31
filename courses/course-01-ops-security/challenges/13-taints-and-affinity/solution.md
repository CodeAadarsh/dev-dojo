# Solution — Pin the Pod

Add a **required** `nodeAffinity` block to the `pinme` pod template, then roll the pods so the old ones (placed before your edit) get rescheduled onto gold.

```yaml
# pinme.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pinme
  namespace: dojo-sched
  labels:
    app: pinme
spec:
  replicas: 3
  selector:
    matchLabels:
      app: pinme
  template:
    metadata:
      labels:
        app: pinme
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:   # HARD rule — Pending if unmet
            nodeSelectorTerms:
              - matchExpressions:
                  - key: tier
                    operator: In
                    values:
                      - gold
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 25m
              memory: 16Mi
```

Apply, then **force a rollout** — this is the step most people miss:

```bash
kubectl apply -f pinme.yaml
kubectl -n dojo-sched rollout restart deploy/pinme      # recreate pods under the new rule
kubectl -n dojo-sched rollout status  deploy/pinme
kubectl -n dojo-sched get pods -o wide                  # confirm NODE column is all gold
bash courses/course-01-ops-security/challenges/13-taints-and-affinity/verify.sh
```

If you prefer not to write YAML, patch the live object:

```bash
kubectl -n dojo-sched patch deploy pinme --type=merge -p '{
  "spec":{"template":{"spec":{"affinity":{"nodeAffinity":{
    "requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[
      {"matchExpressions":[{"key":"tier","operator":"In","values":["gold"]}]}]}}}}}}}'
```

A `patch` to the pod template bumps the template hash and triggers a rollout on its own, so no separate `rollout restart` is needed in that path.

## Why each piece is correct

- **`requiredDuringSchedulingIgnoredDuringExecution`** is a hard admission gate: the scheduler will only place a pod on a node that satisfies the expression, and if none qualifies the pod sits `Pending` with a `FailedScheduling` event. That `Pending` is a *feature* — it's loud, not silent-wrong. A `preferred` rule would happily place the pod on a non-gold node when gold is full, which is exactly the guarantee you were asked not to make.
- **`operator: In` with `values: [gold]`** is deliberately more expressive than a `nodeSelector`. Tomorrow you can widen it to `In (gold, platinum)` or add a second expression for an AZ — no rewrite.
- **`IgnoredDuringExecution`** is the half of the name everyone forgets. Kubernetes does **not** re-evaluate affinity for *already-running* pods, so adding the rule does not evict the pods currently sitting on the wrong workers. You have to recreate them (`rollout restart`, or the implicit roll from a template patch). The verifier's check 3 exists precisely to catch "I added the rule but never rolled."

## Real failure modes (what the verifier is really testing)

| Symptom | Likely cause | Diagnose | Fix |
|---------|--------------|----------|-----|
| New pods `Pending`, `0/1 nodes are available: ... didn't match node affinity` | typo in key/value, or gold label missing | `kubectl -n dojo-sched describe pod <p> \| sed -n '/Events/,$p'` | fix the expression; confirm `kubectl get nodes -l tier=gold` returns a node |
| Verifier says "a pod is running on dojo-worker2, not gold" | added affinity but didn't roll — old pods linger | `kubectl -n dojo-sched get pods -o wide` | `kubectl -n dojo-sched rollout restart deploy/pinme` |
| Pods `Pending` even though gold node looks idle | gold node is cordoned or tainted | `kubectl describe node <gold> \| grep -E 'Taints\|Unschedulable'` | `kubectl uncordon <gold>`, or add a matching toleration |
| Rule ignored entirely, pods still scatter | rule placed under `preferred...` not `required...` | `kubectl -n dojo-sched get deploy pinme -o jsonpath='{.spec.template.spec.affinity.nodeAffinity}'` | move it under `requiredDuringSchedulingIgnoredDuringExecution` |

> **War story.** A team pinned a GPU inference service with `preferredDuringScheduling` affinity to their `gpu=true` pool, reviewed the YAML, saw "affinity: present," and shipped. For a week it was fine — the pool had room. Then a noisy-neighbour batch job filled the GPU nodes, the *preferred* rule silently fell back to CPU-only workers, and inference latency 20x'd with zero scheduling errors in the logs. The fix was one word: `preferred` → `required`. The lesson: *soft affinity fails open, and failing open is invisible until it isn't.* If placement is a correctness requirement, it must be `required`.

## Hardening preview — the belt-and-suspenders version

Affinity pins *your* pod **to** gold, but it does nothing to stop *other* teams' pods from also landing on gold and eating the reserved headroom you were protecting. To make gold exclusive, pair affinity with a **taint**:

```bash
kubectl taint node <gold> tier=gold:NoSchedule        # repel everything by default
```

Then give only `pinme` a matching toleration:

```yaml
      tolerations:
        - key: tier
          operator: Equal
          value: gold
          effect: NoSchedule
```

Now: taint keeps everyone *off* gold, affinity keeps `pinme` *on* gold. That combination — repel-by-default plus explicit attract — is how real dedicated node pools (GPU, licensed, PCI) are built.
