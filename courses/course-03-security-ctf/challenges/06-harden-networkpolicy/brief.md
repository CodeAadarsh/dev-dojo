# Shut the Flat Network

Course 03 so far has been offense: you stole a ServiceAccount token, bound yourself admin, and read Secrets straight out of etcd. Every one of those attacks assumed something true of almost every default cluster — **the pod network is flat**. Any pod can open a TCP connection to any other pod, in any namespace, on any port. One foothold and the whole east-west plane is yours.

This challenge flips to defense. Security review flagged namespace `dojo-hardnet`: a `backend` service that should only ever be called by the frontend tier is reachable from *everything*, including a `client` pod that has no business talking to it. Your job is to close the blast radius with `NetworkPolicy` the way it should have shipped.

## The lay of the land

The setup script planted three things in `dojo-hardnet`:

| Pod | Labels | Role |
|-----|--------|------|
| `backend` | `app=backend` | the protected service, listens on `:80` (nginx) |
| `frontend` | `app=client,role=frontend` | the *only* client allowed to reach backend |
| `attacker` | `app=client,role=other` | an unauthorized client that must be cut off |

Right now every pod can reach `backend:80`. That is the flat network.

## Mission — target state

Apply **two** `NetworkPolicy` objects to `dojo-hardnet`:

1. **A default-deny-ingress policy.** An empty `podSelector: {}` (selects every pod in the namespace), `policyTypes: [Ingress]`, and **no** `ingress` rules. This is the baseline: once it exists, nothing can reach any pod in the namespace until you explicitly allow it.
2. **A scoped allow policy.** Selects the backend (`podSelector.matchLabels.app=backend`) and permits ingress **only** from pods labelled `role=frontend`, **only** on TCP port `80`.

The verifier accepts your work when **all** of these are true:

1. Namespace `dojo-hardnet` exists with the planted pods.
2. A **default-deny-ingress** `NetworkPolicy` exists — empty pod selector, `policyTypes` contains `Ingress`, zero ingress rules.
3. A **matching allow** `NetworkPolicy` exists — it selects `app=backend`, its ingress `from` has a `podSelector` with `role=frontend`, and its `ports` list includes port `80`.

When both policies are in place, run the verifier (step 3 above): it inspects the live policy objects and prints the flag.

## Read this before you test connectivity

> **kindnet does not enforce NetworkPolicy.** The default CNI in `kind` (`kindnet`) implements pod networking but is **not** a policy controller. You can apply a flawless `NetworkPolicy` and `attacker` will *still* reach `backend` — the manifests are accepted and stored, but nothing drops the packets. This is a classic production trap: teams ship NetworkPolicies, never test enforcement, and discover during an incident that their CNI (or a misconfigured one) was ignoring them the whole time.

Because of that, this is a **defensive-posture** challenge: the verifier checks that the correct **policy objects** exist and are well-formed, not that traffic is physically blocked. In a real cluster you would run Cilium, Calico, or Antrea — a CNI that enforces — and then you *would* confirm the drop with a `curl` from `attacker`. The solution shows exactly how.

## Why default-deny-then-allow

The order is the whole lesson. A lone "allow frontend" policy does nothing if there is no deny baseline — NetworkPolicy is **additive**, and a pod with *no* policy selecting it is open to all. You must first select every pod with a deny-all, which flips the namespace to "deny unless allowed," and only *then* punch the single hole you need. Default-deny first, least-privilege allow second: the same shape as a good firewall or a good RBAC Role.
