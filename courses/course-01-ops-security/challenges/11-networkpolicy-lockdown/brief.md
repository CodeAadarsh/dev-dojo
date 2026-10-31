# NetworkPolicy Lockdown

A pentester's report lands on your desk after a tabletop exercise: *"Lateral movement is trivial. Any compromised pod in `dojo-netpol` can reach the backend — and anything else in the namespace — on any port. There is no east-west segmentation."*

They're right, and the reason is the default most teams never think about: **an empty namespace has no NetworkPolicy, and no NetworkPolicy means allow-all.** Pods are a flat L3 network until you say otherwise.

```
            BEFORE (no policy = allow-all)                 AFTER (default-deny + 1 allow)
   ┌──────────────┐        ┌──────────────┐         ┌──────────────┐        ┌──────────────┐
   │ frontend     │──80──▶ │              │         │ frontend     │──80──▶ │              │
   │ (role=       │        │   backend    │         │ (role=       │        │   backend    │
   │  frontend)   │◀─any──│   :80        │         │  frontend)   │        │   :80        │
   └──────────────┘        │  nginx       │         └──────────────┘        │  nginx       │
   ┌──────────────┐        │              │         ┌──────────────┐    ╳   │              │
   │ intruder     │──any─▶ │              │         │ intruder     │──────▶ │   DENIED     │
   │ (role=other) │        └──────────────┘         │ (role=other) │        └──────────────┘
   └──────────────┘                                 └──────────────┘
```

## The model you must hold in your head

NetworkPolicy is **additive and allowlist-only**. There is no "deny" rule — you deny by *selecting* pods and then *not* listing a given source as allowed. Three facts decide everything:

| Fact | Consequence |
|------|-------------|
| A pod is "selected" by a policy if any policy's `podSelector` matches it | Once selected for `Ingress`, only explicitly-allowed sources get in; everything else is dropped. |
| A pod selected by **no** policy | Stays allow-all (the pre-lockdown default). |
| Policies are **unioned** | Two allow rules add up; you can't write a rule that subtracts. The "deny" is the absence of an allow on a selected pod. |

So the canonical pattern is two objects: a **default-deny-ingress** that selects *every* pod in the namespace (and admits nothing), plus a narrow **allow** that re-opens exactly one path.

## Mission

Lock down namespace `dojo-netpol` so that:

1. A **default-deny-ingress** policy exists — `podSelector: {}` (selects all pods), `policyTypes: [Ingress]`, and **no** `ingress:` rules. This flips the namespace from allow-all to deny-all for inbound traffic.
2. A separate **allow** policy exists that selects the backend (`podSelector.matchLabels.app: backend`) and admits ingress **only** from pods labelled `role: frontend`, **only** on **port 80**.

The verifier inspects the policy *objects* and prints the flag when both exist:

- a NetworkPolicy with `policyTypes` including `Ingress`, an empty `podSelector`, and zero ingress rules;
- a NetworkPolicy selecting `app=backend` whose ingress admits `from` a `podSelector` `role=frontend` on port `80`.

## ⚠ Read this before you test with curl

**kind's default CNI, `kindnet`, does NOT enforce NetworkPolicy.** Policies will apply cleanly and `kubectl get netpol` will list them, but packets are *not* dropped — `intruder` can still curl the backend. That is a property of the lab, not a mistake in your YAML.

You have two options:

- **Just author the policies.** The verifier checks the policy objects, not live packet drops — this is enough to clear the challenge and is how you'd be graded in a real PR review.
- **Want real enforcement?** Recreate the cluster with a policy-enforcing CNI (Calico):
  ```bash
  kind delete cluster --name dojo
  kind create cluster --name dojo --config=- <<'EOF'
  kind: Cluster
  apiVersion: kind.x-k8s.io/v1alpha4
  networking:
    disableDefaultCNI: true
    podSubnet: "192.168.0.0/16"
  EOF
  kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
  ```
  Then re-run `setup.sh` and watch `intruder`'s curl hang while `frontend`'s succeeds.

## Why this matters

Flat pod networks are how a single RCE in one pod becomes a cluster-wide breach. **Default-deny per namespace is the single highest-leverage network control you can ship** — it turns "any pod can reach anything" into "nothing talks until I say so." Every allow you then write becomes an auditable, reviewable statement of intent. This is the Kubernetes expression of zero-trust east-west.
