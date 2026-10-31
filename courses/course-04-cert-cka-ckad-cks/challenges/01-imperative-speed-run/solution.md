# Solution — Imperative Speed Run

Two commands. That's the whole point of the drill.

## Step 0 — stop typing `-n` (saves a token on every command)

```bash
kubectl config set-context --current --namespace=dojo-exam
```

## Step 1 — the Deployment

```bash
kubectl create deploy speedy --image=nginx:1.27-alpine --replicas=3
```

That single line satisfies three of the five checks: Deployment named `speedy`, 3 replicas, nginx image. `kubectl create deploy` stamps the pod template with `app=speedy` as the selector label automatically — which is what the Service will key off next.

## Step 2 — expose it

```bash
kubectl expose deploy speedy --port=80 --target-port=80
```

`kubectl expose` defaults to `type: ClusterIP`, and — critically — it reads the selector off the Deployment (`app=speedy`) so the Service actually routes to the pods. That's why it beats `kubectl create svc clusterip speedy --tcp=80:80`, which creates a Service with a generic `app=speedy` selector only by coincidence of naming and gives you no wiring guarantee against a differently-named Deployment.

## Verify

```bash
kubectl -n dojo-exam get deploy,svc,endpoints speedy
bash courses/course-04-cert-cka-ckad-cks/challenges/01-imperative-speed-run/verify.sh
```

`kubectl get endpoints speedy` is the real-world confirmation the Service is wired: once the pods are Ready you'll see three `IP:80` endpoints. Empty endpoints means the Service selector doesn't match the pods — the single most common "my Service doesn't work" bug.

## The YAML-generator variant (when a task needs a field expose can't set)

For a task that also wants, say, a readiness probe or a resource request, you can't do it in one `expose` — generate and edit instead:

```bash
kubectl create deploy speedy --image=nginx:1.27-alpine --replicas=3 \
  --dry-run=client -o yaml > speedy.yaml
# edit speedy.yaml to add the extra fields, then:
kubectl apply -f speedy.yaml
kubectl expose deploy speedy --port=80 --target-port=80
```

Generate the skeleton, edit the file, apply. Never hand-author a Deployment from a blank buffer under the clock.

## Why the time target matters

In the real CKAD this is a ~90-second task. If it took you five minutes, the culprit is almost always one of: not setting the default namespace, hand-typing YAML, or reaching for `kubectl create svc` and then fighting the selector. Fix those three habits and this class of task becomes free points — which is exactly the margin that lets you finish the exam.

## Attacker's view (why a bare `expose` on port 80 is a CKS footnote)

A ClusterIP Service with no NetworkPolicy means *every* pod in the cluster can reach `speedy:80`. On CKAD that's fine — it's what the task asked for. On **CKS**, the follow-up task would be "now add a default-deny NetworkPolicy and only allow the `frontend` namespace to reach it." Keep that in mind: the CKAD habit of exposing freely is the exact surface CKS asks you to lock down later.
