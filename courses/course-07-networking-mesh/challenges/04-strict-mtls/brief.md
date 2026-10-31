# Strict mTLS Enforcement

The security team just ran a mesh-wide audit and found `dojo-mtls` sitting in `PERMISSIVE` mode — Istio will happily accept plaintext connections alongside mTLS ones. In an east-west traffic model where every sidecar is trusted, that's a standing invitation for a compromised pod to impersonate any service without a valid cert.

Your job: flip the namespace to `STRICT` mTLS via a `PeerAuthentication` policy, so Istio rejects every plaintext connection at the sidecar level before it reaches your container.

## Background

Istio's mTLS has two layers:

| Layer | Object | Controls |
|-------|--------|----------|
| **Authentication** | `PeerAuthentication` (`security.istio.io/v1`) | Whether the sidecar *accepts* plaintext. `PERMISSIVE` = both; `STRICT` = mTLS only. |
| **Authorization** | `AuthorizationPolicy` | Which authenticated principals are *allowed*. Out of scope here. |

A namespace-scoped `PeerAuthentication` (no `selector`) applies to every pod in that namespace. A workload-scoped one (with `selector`) overrides it per-app. Strict at the namespace level is the correct default; relax per-workload only when you have a proven reason.

> **PREREQ:** Istio must be installed on the cluster and the namespace `dojo-mtls` must have the label `istio-injection=enabled`. The setup script creates the namespace with that label and deploys a test app.
>
> Install Istio (if not present):
> ```bash
> curl -L https://istio.io/downloadIstio | sh -
> istioctl install --set profile=demo -y
> ```
> You do NOT need a gateway — the sidecar mesh is enough for this challenge.

## Mission

Author a `PeerAuthentication` resource named `default` in namespace `dojo-mtls` that sets `spec.mtls.mode: STRICT`.

The verifier checks:
1. A `PeerAuthentication` named `default` exists in `dojo-mtls`.
2. `spec.mtls.mode` is `STRICT`.
3. No workload `selector` is set (namespace-wide policy).

Once the verifier passes, it prints the flag.

## Rules of engagement

- Namespace is `dojo-mtls` (setup script creates it with the Istio injection label).
- The `PeerAuthentication` must be named `default` to act as the namespace default.
- API group: `security.istio.io/v1` (or `security.istio.io/v1beta1` — both are accepted by the cluster).
- Do not add a `selector` — this should apply to every workload in the namespace.
