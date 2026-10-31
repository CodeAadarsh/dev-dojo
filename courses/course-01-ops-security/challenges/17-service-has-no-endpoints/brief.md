# No Endpoints, No Service

A frontend team files a ticket: *"Calls to `http://api.dojo-endpoints.svc` time out. The api pods are all green though — is it a network policy?"* You check, and the pods really are healthy:

```
NAME                   READY   STATUS    RESTARTS   AGE
api-6b8d9c7f5-2mnq4    1/1     Running   0          4m
api-6b8d9c7f5-7xk8p    1/1     Running   0          4m
api-6b8d9c7f5- td4rl   1/1     Running   0          4m
```

Three Ready pods, zero restarts, serving nginx on `:80`. And yet every request to the Service hangs or is refused. This is one of the most common "but the pods are fine!" incidents in Kubernetes, and it has a single, fast tell.

## The mental model: a Service is just a label selector

A `ClusterIP` Service is **not** a proxy that knows about your Deployment. It is a stable virtual IP plus a **label selector**. The endpoints controller continuously lists pods matching that selector, filters to the **Ready** ones, and writes their IPs into an `Endpoints` / `EndpointSlice` object. `kube-proxy` (or the CNI) then load-balances the Service IP across exactly those addresses.

```
   Service (clusterIP)        EndpointSlice              Ready pods
   selector: app=???  ──────▶  [ 10.244.1.5:80          ┌─ app=api ─┐
                               10.244.2.7:80  ] ◀────── │ pod pod pod │
                                      ▲                  └───────────┘
                              endpoints controller
                              matches selector → Ready pod IPs
```

If the selector matches **no** pods, the EndpointSlice is empty, there is nothing to load-balance to, and the Service silently blackholes traffic — no error, just timeouts. **No endpoints, no service.**

## Diagnose: the one command that ends the argument

Before you blame DNS, NetworkPolicy, or the CNI, ask the Service who's behind it:

| Step | Command | What a healthy answer looks like |
|------|---------|----------------------------------|
| 1 | `kubectl -n dojo-endpoints get endpoints api` | A list of `IP:port` pairs. **`<none>`** means the selector matches nothing — stop here, that's your bug. |
| 2 | `kubectl -n dojo-endpoints get endpointslices -l kubernetes.io/service-name=api` | Same truth, the modern object. Empty `endpoints:` = no backends. |
| 3 | `kubectl -n dojo-endpoints describe svc api` | Read the `Selector:` line — then compare it to reality. |
| 4 | `kubectl -n dojo-endpoints get pods --show-labels` | The labels the pods *actually* carry. The mismatch jumps out. |

The two-line check that isolates it instantly:

```bash
kubectl -n dojo-endpoints get svc api -o jsonpath='{.spec.selector}{"\n"}'   # what the Service looks for
kubectl -n dojo-endpoints get pods --show-labels                              # what the pods have
```

> **War story.** An on-call engineer burned two hours during an incident chasing a "DNS problem" — `nslookup` resolved the Service name fine, so surely it was the pods or a NetworkPolicy. It was neither. A Helm values change had renamed the pod label from `app: api` to `app.kubernetes.io/name: api`, but the Service selector still said `app: api`. DNS resolving only proves the Service *object* exists; it says nothing about whether anything is **behind** it. `kubectl get endpoints` showed `<none>` in two seconds. **Always ask the Service for its endpoints before you touch DNS or network policy.**

## Mission

Make the `api` Service in `dojo-endpoints` actually route to the `api` pods. The verifier accepts your work only when **all** of these are true:

1. **The Service `api` exists** in `dojo-endpoints` and still targets port `80`.
2. **Its EndpointSlice (and `Endpoints`) is non-empty** — at least one Ready pod IP backs the Service.
3. The backing addresses are the real `app=api` pod IPs (i.e. you fixed the selector/port, not faked an Endpoints object).

## Rules of engagement

- Work in namespace `dojo-endpoints` (the setup script creates it).
- Fix the **Service** so it selects the running pods. Don't relabel the pods to a stale name, and don't hand-write a manual `Endpoints` object to trick the check — fix the selector (and confirm the port lines up).
- Imperative (`kubectl patch`/`edit`) or declarative (`apply`) is fine; the verifier only inspects final state.

When the Service has live endpoints, run the verifier. It prints the flag once real pod IPs back the Service.
