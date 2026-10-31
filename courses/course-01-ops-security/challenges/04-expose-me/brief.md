# Expose Me

A teammate deployed the `shop` frontend to `dojo-expose`, saw three `Running` pods, closed the ticket, and went to lunch. Then the on-call pinged: *"the gateway can't reach shop, DNS resolves to nothing."*

The pods are fine. What's missing is the thing that turns a set of fungible, churning pods into one stable name you can route to: a **Service**. A Deployment gives you pods with ephemeral IPs that change on every reschedule; a Service gives you a stable virtual IP (ClusterIP) and a DNS name, and — the part people forget — it only works if its **selector actually matches running, ready pods**.

Your job: put a ClusterIP Service in front of the `shop` Deployment so `shop.dojo-expose.svc.cluster.local:80` resolves and load-balances to the pods.

## How a Service really wires up

```
            ┌──────────────── dojo-expose ────────────────┐
            │                                              │
  DNS   ┌───┴────┐   selector        ┌───────────────┐     │
 shop ─▶│ Service│  app=shop  ──────▶│ EndpointSlice │     │
 :80    │ClusterIP│  matches          │ 10.244.x.a:80 │     │
        └───┬────┘                    │ 10.244.x.b:80 │     │
            │                         │ 10.244.x.c:80 │     │
            │   kube-proxy programs   └───────┬───────┘     │
            │   these as iptables/IPVS         │            │
            ▼                                  ▼            │
        virtual IP ───────────────────▶  3 ready shop pods  │
            └──────────────────────────────────────────────┘
```

The Service's `selector` is a **continuous query**, not a one-time bind. The endpoints controller watches for pods matching the selector that are `Ready`, and writes their IPs into an **EndpointSlice** (the modern replacement for the single `Endpoints` object). `kube-proxy` turns those into dataplane rules. If the selector matches nothing — wrong label, wrong namespace, pods not Ready — the Service exists, DNS resolves, and every connection **hangs or refuses**, because the backend list is empty. That is the single most common "my Service doesn't work" bug, and it never shows up in `kubectl get svc`.

## Target state

The verifier accepts your work only when **all** of these are true in namespace `dojo-expose`:

1. **A Service exists** in `dojo-expose`.
2. Its **selector is exactly `app=shop`** — matching the Deployment's pods.
3. It serves on **port 80** (`spec.ports[0].port == 80`).
4. It has **non-empty, ready Endpoints** — i.e. the selector actually resolved to running pods and their addresses are published in an EndpointSlice. This is the check that proves the Service is *useful*, not just present.

A `ClusterIP` type is all you need (it is also the default `type`). The verifier does not care about the Service's name.

## Rules of engagement

- Work in namespace `dojo-expose` (the setup script creates it and the Deployment).
- Imperative (`kubectl expose`) or declarative YAML (`kubectl apply`) — either is fine; the verifier inspects final state only.
- The pods run `nginx:1.27-alpine` serving on container port 80.

> **Optional — go further with Ingress.** Once the Service is up you can front it with an Ingress for host/path routing. That needs an ingress controller, which is **not** installed in the base cluster — run `bash labs/bootstrap/install-ingress.sh` first if you want to try it. The required verifier checks stop at Service + Endpoints, so the challenge passes with or without ingress installed.

When the cluster is in the target state, run the verifier. It inspects your live Service and its endpoints and prints the flag only if every check passes.
