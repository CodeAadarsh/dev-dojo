# Solution — Drain Gracefully

One edit to the Deployment's pod template fixes all four checks: a `preStop` drain, a grace period that covers it, and a readiness probe.

```yaml
# web.yaml — kubectl apply -f web.yaml  (or kubectl -n dojo-grace edit deploy web)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: dojo-grace
  labels:
    app: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      terminationGracePeriodSeconds: 30     # (2) budget = preStop sleep (15) + SIGTERM handling headroom (15)
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          readinessProbe:                   # (3) controls when the pod enters/leaves rotation
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
          lifecycle:
            preStop:                         # (1) runs to completion BEFORE SIGTERM
              exec:
                command: ["/bin/sh", "-c", "sleep 15"]
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
```

Apply, wait for the roll, verify:

```bash
kubectl apply -f web.yaml
kubectl -n dojo-grace rollout status deploy/web
bash courses/course-02-sre-production/challenges/06-graceful-shutdown/verify.sh
```

## Why each piece is correct

- **`preStop: sleep 15` is the whole trick.** The hook runs to completion *before* the kubelet sends SIGTERM. During those 15 seconds the pod has already been removed from the Service's Endpoints, and kube-proxy on every node has time to drop its stale iptables/ipvs rule. By the time your app finally gets SIGTERM, no new connections are being routed to it. For a plain static-content nginx, `sleep` is the canonical hook; for an app that holds long-lived connections you'd *also* have it stop accepting new work on SIGTERM and finish in-flight requests — the sleep covers the routing race, graceful SIGTERM handling covers the in-flight requests.
- **`terminationGracePeriodSeconds` is the total budget, not extra time.** The clock starts at `t=0` (pod Terminating) and covers `preStop` **plus** SIGTERM handling. With `preStop` at 15s and grace at 30s, the app gets ~15s to shut down cleanly after the drain; at `t=30` the kubelet SIGKILLs whatever's left. Set grace *equal to or below* the sleep and the kubelet kills the container the instant the sleep ends — the app never sees a clean SIGTERM. That's exactly the mistake the verifier rejects (`grace >= sleep`, with real deployments wanting `grace > sleep`).
- **The `readinessProbe` works both directions.** It gates a pod *into* rotation (no traffic until `/` answers), and — paired with the endpoint controller — it's what lets Kubernetes pull the pod *out* promptly when it goes unready on shutdown. Without it, the service's notion of "which pods can serve" is just "which pods have a running container," which is coarse and wrong during both startup and teardown.

## Prove it actually drains

Hammer the Service through a client while you roll the Deployment, and watch for resets:

```bash
# in terminal 1 — continuous requests through the Service from inside the cluster
kubectl -n dojo-grace run hammer --image=nicolaka/netshoot:v0.13 --restart=Never -- \
  /bin/sh -c 'while true; do curl -s -o /dev/null -w "%{http_code}\n" http://web.dojo-grace.svc || echo RESET; done'
kubectl -n dojo-grace logs -f hammer | grep -v '^200$'   # terminal 2: show only non-200s / RESETs

# in terminal 3 — trigger a rollout (any spec change rolls the pods)
kubectl -n dojo-grace rollout restart deploy/web
```

**Before the fix** you'll see a burst of `000`/`RESET`/`502` lines each time a pod terminates. **After the fix** the non-200 stream stays silent through the roll. Clean up with `kubectl -n dojo-grace delete pod hammer`.

You can confirm the hook is wired correctly without a rollout:

```bash
kubectl -n dojo-grace get deploy web -o jsonpath='{.spec.template.spec.containers[0].lifecycle.preStop}{"\n"}'
kubectl -n dojo-grace get deploy web -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}{"\n"}'
```

## Hardening preview — where the sleep hack ends

`preStop: sleep` papers over an *eventually-consistent* dataplane; it does not make shutdown synchronous. In larger systems you graduate to:

- **SIGTERM-aware apps** that flip a readiness flag to fail on SIGTERM, stop accepting new work, and drain their own in-flight requests + connection pools — the sleep only buys the routing layer time; the app still has to cooperate.
- **Ingress / service mesh draining** (Envoy, NGINX Ingress) with their own connection-draining timeouts, because the pod leaving `Endpoints` and the *proxy* actually closing upstreams are two more non-synchronized steps.
- **`maxUnavailable: 0` + a PDB** (from Course 01) so draining is paced pod-by-pod and you never lose capacity while a batch of pods is mid-drain.

The lesson that generalizes: **termination in Kubernetes is a set of parallel, eventually-consistent events, and resilience means refusing to exit until the slowest one has caught up.**
