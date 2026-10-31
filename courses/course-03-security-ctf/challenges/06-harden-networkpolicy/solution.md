# Solution — Shut the Flat Network

Two manifests. The first flips the namespace to deny-by-default; the second opens exactly one hole.

## Step 1 — default-deny-ingress

```yaml
# deny.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: dojo-hardnet
spec:
  podSelector: {}            # select EVERY pod in the namespace
  policyTypes:
    - Ingress                # govern ingress...
  # no ingress: rules        # ...and allow none -> deny all inbound
```

The three load-bearing pieces: `podSelector: {}` selects all pods, `policyTypes: [Ingress]` declares this policy governs inbound traffic, and the *absence* of any `ingress:` block means "zero allowed sources." Together that is the canonical default-deny.

## Step 2 — scoped allow

```yaml
# allow.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: dojo-hardnet
spec:
  podSelector:
    matchLabels:
      app: backend           # this policy protects the backend pods
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              role: frontend # ...only pods labelled role=frontend may enter
      ports:
        - protocol: TCP
          port: 80           # ...and only on :80
```

Apply both and verify:

```bash
kubectl apply -f deny.yaml -f allow.yaml
bash courses/course-03-security-ctf/challenges/06-harden-networkpolicy/verify.sh
```

## Why order and additivity matter

NetworkPolicy is **additive and permissive-union**: a pod is "isolated" only once *some* policy selects it, and then the allowed traffic is the union of every matching policy's rules. Consequences that trip people up:

- Apply **only** the allow policy and `attacker` is still blocked from `backend` **but** every *other* pod in the namespace remains wide open — because nothing selects them, so they are not isolated. The deny-all is what brings the rest of the namespace under policy.
- There is no "deny" rule type. You express "deny" as "select the pod, allow nothing, then add back the narrow allows." Firewalls think the same way.
- Ingress and egress are independent. This challenge locks ingress; a complete posture usually adds a default-deny-egress too, then allow-lists DNS (`kube-dns` on :53) and the specific upstreams.

## The attacker's view / confirming enforcement

```bash
# from the UNauthorized client — should hang then fail on an enforcing CNI
kubectl -n dojo-hardnet exec attacker -- \
  wget -qO- --timeout=3 http://backend.dojo-hardnet.svc 2>&1 | head -1

# from the authorized client — should return nginx's welcome HTML
kubectl -n dojo-hardnet exec frontend -- \
  wget -qO- --timeout=3 http://backend.dojo-hardnet.svc 2>&1 | head -1
```

> **kindnet caveat (read the brief).** Under the default `kind` CNI both commands *succeed* — kindnet stores your policies but never enforces them, so the packets flow regardless. That is why this challenge's verifier asserts on the policy objects, not on a live drop. To actually watch `attacker` get blocked, recreate the cluster with an enforcing CNI:
>
> ```bash
> kind create cluster --name dojo --config - <<'EOF'
> kind: Cluster
> apiVersion: kind.x-k8s.io/v1alpha4
> networking:
>   disableDefaultCNI: true
>   podSubnet: "10.244.0.0/16"
> EOF
> # then install Calico or Cilium, e.g.:
> kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
> ```
>
> With Calico installed, the `attacker` `wget` times out and the `frontend` one returns HTML — enforcement you can see. **The lesson that outlives the lab: a NetworkPolicy you never tested against a real enforcing CNI is a false sense of security.** Audit which controller is actually running (`kubectl -n kube-system get pods`) before you trust a single policy in production.

## Hardening checklist (beyond this challenge)

- Add a `default-deny-egress` and allow-list DNS + known upstreams, so a compromised pod can't exfiltrate or call home.
- Put a default-deny in **every** namespace, not just the sensitive one — flat networks are a per-namespace property.
- Prefer label-based `podSelector` over `ipBlock` for in-cluster rules; IPs churn, labels are intent.
- Consider `AdminNetworkPolicy` (the newer cluster-scoped API) for guardrails that namespace owners cannot override.
