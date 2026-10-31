# Solution — Stateful Identity

Two manifests: the headless Service first (the StatefulSet references it by name), then the StatefulSet itself.

```yaml
# 01-headless-svc.yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: dojo-sts
  labels:
    app: web
spec:
  clusterIP: None          # headless — one A record per Ready pod endpoint
  selector:
    app: web               # must match StatefulSet pod template labels exactly
  ports:
    - port: 80
      name: http
---
# 02-statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: web
  namespace: dojo-sts
spec:
  serviceName: "web"       # references the headless Service above
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 3
            periodSeconds: 5
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
          volumeMounts:
            - name: data
              mountPath: /usr/share/nginx/html
  volumeClaimTemplates:
    - metadata:
        name: data             # PVCs are stamped: data-web-0, data-web-1, data-web-2
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: standard
        resources:
          requests:
            storage: 1Gi
```

Apply, wait, then verify:

```bash
kubectl apply -f 01-headless-svc.yaml
kubectl apply -f 02-statefulset.yaml
kubectl -n dojo-sts rollout status sts/web
kubectl -n dojo-sts get pods,pvc
bash courses/course-08-stateful-data/challenges/01-stateful-identity/verify.sh
```

## Why each piece matters

- **Service before StatefulSet** — the StatefulSet `spec.serviceName` field is advisory at creation time, but per-pod DNS entries are only created once the headless Service exists. Create it first and you never debug NXDOMAIN surprises.
- **`clusterIP: None`** — this single field tells the kube-proxy to skip VIP allocation. Instead, the DNS server creates one A record per Ready endpoint. `web-0.web.dojo-sts.svc.cluster.local` resolves to the IP of exactly pod `web-0`. Change it to anything non-None and you get a VIP round-robin — pods are no longer individually addressable.
- **`selector` must match** — if the Service selector is `app: web` but pods carry `app: nginx`, `kubectl get endpoints web -n dojo-sts` shows `<none>` and all per-pod DNS is silently broken. This is the most common StatefulSet DNS bug. Always check endpoints, not just the Service.
- **`volumeClaimTemplates[0].name: data`** — Kubernetes constructs PVC names as `<template-name>-<statefulset-name>-<ordinal>`. Choosing `data` as the template name gives predictable, checkable names: `data-web-0`, `data-web-1`, `data-web-2`. When `web-1` is rescheduled to another node, Kubernetes re-attaches `data-web-1` — the same PVC, the same data.
- **`storageClassName: standard`** — kind's default class uses `WaitForFirstConsumer`. The PVCs start `Pending` and only bind once each pod is scheduled; you'll watch them flip to `Bound` as the StatefulSet starts pods one by one (ordinal 0 → 1 → 2).

## Prove per-pod DNS

```bash
kubectl run -n dojo-sts dns-test --rm -it --image=busybox:1.36 \
  --restart=Never -- sh -c \
  "nslookup web-0.web.dojo-sts.svc.cluster.local && \
   nslookup web-1.web.dojo-sts.svc.cluster.local && \
   nslookup web.dojo-sts.svc.cluster.local"
```

The per-pod lookups each return exactly one IP. The service lookup returns all three. That's the headless DNS contract.

## Hardening note

PVC names are deterministic and namespace-scoped. Any workload in `dojo-sts` with `create pod` permission can mount `data-web-0` by name — it just adds `claimName: data-web-0` to its volumes. Stateful data is only as isolated as your RBAC and namespace boundaries. In production: one namespace per stateful tier, tightly scoped ServiceAccounts, and RBAC that restricts who can create pods in that namespace.
