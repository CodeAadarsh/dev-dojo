# Solution — NetworkPolicy Lockdown

Two objects. The first denies all ingress namespace-wide; the second re-opens exactly one path.

```yaml
# 1) default-deny-ingress.yaml — selects EVERY pod, admits NOTHING
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: dojo-netpol
spec:
  podSelector: {}            # empty = matches every pod in the namespace
  policyTypes:
    - Ingress                # govern inbound only; egress stays allow-all
  # NOTE: no `ingress:` block at all → zero allowed sources → deny all inbound
---
# 2) allow-frontend-to-backend.yaml — the single re-opened path
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: dojo-netpol
spec:
  podSelector:
    matchLabels:
      app: backend           # this policy applies TO backend pods
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              role: frontend # allowed SOURCE: pods labelled role=frontend
      ports:
        - protocol: TCP
          port: 80           # only on :80
```

Apply and verify:

```bash
kubectl apply -f default-deny-ingress.yaml -f allow-frontend-to-backend.yaml
kubectl -n dojo-netpol get netpol
bash courses/course-01-ops-security/challenges/11-networkpolicy-lockdown/verify.sh
```

## Why each piece is exactly this

- **`podSelector: {}` + no `ingress:`** is the deny-all idiom. The empty selector makes the policy apply to every pod; listing `Ingress` in `policyTypes` with no rules means "selected for ingress, zero sources allowed." That is the flip from allow-all to deny-all.
- **The allow is a *separate* object**, not an edit to the deny. Policies union — you never "modify the deny to add an exception." You add a new allow that selects the target and names the permitted source. Reviewers can read `allow-frontend-to-backend` as a one-line statement of intent.
- **`from.podSelector role=frontend` is identity, not IP.** You're allowing a *workload class*, not a brittle CIDR. Relabel a pod `role=frontend` and it gains access; that's the feature.
- **`ports: [80]` scopes the hole.** Without it, the allow would open every port on backend to frontends. Least privilege applies to ports too.

### The two most common ways this is written wrong

| Mistake | What actually happens |
|---------|-----------------------|
| `from` uses only `namespaceSelector`, no `podSelector` | Every pod in the matched namespace gets in, not just `role=frontend`. |
| A `namespaceSelector` and a `podSelector` listed as **two items** under `from` | OR semantics: "this namespace OR these pods" — far wider than intended. To mean AND, put both keys under **one** `from` list item. |
| Omitting `ports` | The allow opens *all* ports on backend, not just 80. |
| Editing the deny to add an exception | There is no "except" in NetworkPolicy. Add a new allow instead. |

## Debugging NetworkPolicy

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Policy applied but `intruder` still reaches backend | kindnet doesn't enforce NetworkPolicy | Expected in this lab — verifier checks objects. For real enforcement, recreate with Calico (see brief). |
| *Everything* is blocked, even frontend | default-deny present but the allow doesn't match (wrong label/port) | `kubectl describe netpol allow-frontend-to-backend` and check the podSelector + from + ports. |
| Allow seems ignored | Allow policy selects the wrong pods (`app` key typo) or wrong source label | Confirm backend carries `app=backend` and the client carries `role=frontend`: `kubectl -n dojo-netpol get pod --show-labels`. |
| DNS breaks after lockdown | You added a default-deny-**egress** too, blocking kube-dns on :53 | Add an egress allow to `kube-system` on UDP/TCP 53, or keep egress out of scope here. |

Diagnostic commands:

```bash
kubectl -n dojo-netpol get netpol
kubectl -n dojo-netpol describe netpol default-deny-ingress
kubectl -n dojo-netpol get pod --show-labels                      # verify role= / app= labels
# With a policy-enforcing CNI, prove the drop and the allow:
kubectl -n dojo-netpol exec intruder -- wget -qO- --timeout=3 http://backend   # should hang/fail
kubectl -n dojo-netpol exec frontend -- wget -qO- --timeout=3 http://backend   # should return nginx
```

> **War story.** A fintech team shipped a textbook `default-deny-ingress` to their payments namespace on a Friday and went home proud. Saturday 02:00, pager storm: the service was up, health checks green, but every request 500'd. The deny selected *all* pods for ingress — including the app's own sidecar that the main container called over `localhost`... no, worse: they'd *also* dropped in a default-deny-**egress** from a copied gist, and the app could no longer resolve DNS because port 53 to `kube-system` was now denied. The lesson that stuck: **add deny-egress and deny-ingress as separate, deliberate changes, and always pair a deny-egress with an explicit allow to kube-dns on :53.** Ingress-only default-deny — what this challenge asks for — is the safe place to start.

## Hardening preview

- Add a matching **default-deny-egress** per namespace plus an explicit allow to kube-dns — then allowlist each outbound dependency. This stops a compromised pod from exfiltrating or calling home.
- Use **`namespaceSelector` + `podSelector` together** (same `from` item) for cross-namespace allows so you don't accidentally open a whole namespace.
- Treat policies as code: a PR that adds an allow is a reviewable security decision. Pair with a policy linter / Cilium or Calico visibility so you can see what's actually flowing before you tighten.

## Checkpoint

You've internalized this when you can:

1. Explain why "no NetworkPolicy" means allow-all, and why a deny is the *absence* of an allow on a selected pod.
2. Write a default-deny-ingress from memory (`podSelector: {}`, `policyTypes: [Ingress]`, no rules).
3. Say why the `namespaceSelector`/`podSelector` AND-vs-OR distinction matters in a single `from` list.
4. Scope an allow to a specific port, not just a source.
5. Recognize that kindnet won't enforce it and know the Calico recreate path when you need real drops.
