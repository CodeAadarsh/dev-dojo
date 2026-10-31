# Solution — No Endpoints, No Service

## Root cause

The Service `api` was shipped with `selector: app=apiv1`, but the Deployment's pods are labelled `app=api`. The endpoints controller found zero pods matching `app=apiv1`, so the EndpointSlice is empty and the Service blackholes every connection — even though the pods are perfectly healthy.

## Confirm it in two seconds

```bash
kubectl -n dojo-endpoints get endpoints api
# NAME   ENDPOINTS   AGE
# api    <none>      5m        <-- the entire incident, in one word

kubectl -n dojo-endpoints get svc api -o jsonpath='{.spec.selector}{"\n"}'
# {"app":"apiv1"}

kubectl -n dojo-endpoints get pods --show-labels | head
# ... app=api        <-- selector looks for apiv1, pods carry api
```

`<none>` endpoints + a selector that doesn't appear in `--show-labels` = selector mismatch. Done diagnosing.

## The fix

Point the Service's selector at the label the pods actually have. Imperative patch is cleanest:

```bash
kubectl -n dojo-endpoints patch svc api \
  --type=merge -p '{"spec":{"selector":{"app":"api"}}}'
```

Or edit the manifest and re-apply:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: dojo-endpoints
spec:
  type: ClusterIP
  selector:
    app: api          # was app: apiv1 — now matches the pods
  ports:
    - name: http
      port: 80
      targetPort: 80  # must match the container's named/numeric port
```

```bash
kubectl apply -f api-svc.yaml
```

Endpoints populate within a second or two:

```bash
kubectl -n dojo-endpoints get endpoints api
# NAME   ENDPOINTS                                        AGE
# api    10.244.1.5:80,10.244.2.7:80,10.244.1.6:80        6m

bash courses/course-01-ops-security/challenges/17-service-has-no-endpoints/verify.sh
```

## Prove it end to end

Resolve and hit the Service from inside the cluster with a throwaway debug pod:

```bash
kubectl -n dojo-endpoints run tmp --rm -it --image=nicolaka/netshoot --restart=Never -- \
  sh -c 'curl -s -o /dev/null -w "%{http_code}\n" http://api.dojo-endpoints.svc/'
# -> 200
```

Before the fix this hangs; after it, `200`.

## The decision tree for "Service has no endpoints"

Selector mismatch is the most common cause, but not the only one. When `get endpoints` shows `<none>`:

| Check | Command | If this is the problem |
|-------|---------|------------------------|
| Selector vs pod labels | `get svc -o jsonpath='{.spec.selector}'` vs `get pods --show-labels` | Fix the selector (our case) |
| Pods actually Ready | `get pods -o wide` | Endpoints only include **Ready** pods — a failing readinessProbe removes a pod from the Service even while it's Running |
| `targetPort` vs containerPort | `describe svc` vs `get pod -o jsonpath='{...containers[*].ports}'` | A right selector but wrong `targetPort` connects but refuses — align them (named ports are safest) |
| Headless/manual service | `get svc -o jsonpath='{.spec.clusterIP}'` | `clusterIP: None` with no selector needs a hand-managed Endpoints/EndpointSlice |

The reflex to internalize: **readiness drives endpoints.** The same mechanism that makes this Service empty is what gives you zero-downtime rollouts — a pod leaves the Service's endpoint set the instant it goes unready, and rejoins when it recovers.

## Security footnote

A selector is a contract on labels, and labels are mutable metadata, not identity. A workload that relabels itself (or a second Deployment that happens to carry `app=api`) will silently start receiving a Service's traffic. In multi-tenant namespaces, pair Service selectors with `NetworkPolicy` so "who can be an endpoint" and "who can actually connect" are enforced independently — a label typo should never route production traffic to the wrong workload.
