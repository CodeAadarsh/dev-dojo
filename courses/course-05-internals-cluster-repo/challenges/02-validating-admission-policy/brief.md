# Ban the Latest

A post-incident review lands on your desk. A Friday deploy pulled a *different* image than the one that passed staging two hours earlier — because both were tagged `:latest` and the upstream had been re-pushed in between. Mutable tags turned a "no-op redeploy" into an unreviewed version bump in production. The action item: **the cluster must refuse `:latest` (and untagged) images at admission time.** Not a lint rule in CI that someone can `--no-verify` past — an API-server-enforced gate that a `kubectl apply` cannot slip past.

Historically this meant standing up an admission **webhook** (a TLS server you run, certify, and keep alive) or installing **OPA Gatekeeper**. On Kubernetes 1.30+ the API server does it natively with **ValidatingAdmissionPolicy** + CEL — no extra pods, no cert rotation, no webhook latency in your request path. That's what you'll ship here.

## How admission works (the 10-second model)

```
  kubectl apply
      │
      ▼
  kube-apiserver ─► authn ─► authz(RBAC) ─► MUTATING admission ─► schema validation
                                                                        │
                                                 VALIDATING admission ◄──┘
                                              (webhooks + ValidatingAdmissionPolicy)
                                                                        │
                                                   accepted ──► persisted to etcd
                                                   rejected ──► 4xx back to kubectl
```

Your policy runs in the **validating** phase: it cannot change the object, only accept or reject it, and it runs on every create/update that matches its constraints — including server-side dry-run.

## Mission

Create a **`ValidatingAdmissionPolicy`** and a **`ValidatingAdmissionPolicyBinding`** (API group `admissionregistration.k8s.io/v1`, available on this kind 1.3x cluster) that **reject any Pod or Deployment whose container images use the `:latest` tag or carry no tag at all**, scoped to namespace **`dojo-admission`** (the setup script creates it).

The verifier accepts your work only when **all** of these hold:

1. A `ValidatingAdmissionPolicy` exists.
2. A `ValidatingAdmissionPolicyBinding` exists (a policy with no binding is inert — it is *defined* but enforces nothing).
3. In `dojo-admission`, a `:latest` image is **REJECTED**:
   ```bash
   kubectl -n dojo-admission run bad --image=nginx:latest --restart=Never --dry-run=server
   # must FAIL (non-zero exit, denied by your policy)
   ```
4. In `dojo-admission`, a pinned tag is **ADMITTED**:
   ```bash
   kubectl -n dojo-admission run good --image=nginx:1.27-alpine --restart=Never --dry-run=server
   # must SUCCEED
   ```

> The verifier uses `--dry-run=server`: the request goes all the way through admission (so your policy is exercised for real) but nothing is persisted, so running the verifier repeatedly leaves no junk pods behind.

## Why this is the expert move

| Approach | What you run | Cost |
|----------|--------------|------|
| CI lint (e.g. kubeconform/conftest) | a pipeline step | bypassable with `--no-verify`, doesn't cover `kubectl apply` by hand |
| Validating **webhook** | your own HTTPS server + serving cert + `failurePolicy` tuning | a pod in the request path; if it's down, you either fail-open (no enforcement) or fail-closed (you can't deploy) |
| OPA **Gatekeeper** | a controller + CRDs + Rego | powerful, but a whole subsystem to run and upgrade |
| **ValidatingAdmissionPolicy** (CEL) | two YAML objects | runs *in* the API server — no extra process, no cert, no network hop |

CEL evaluation is in-process and fast, there is nothing to keep alive, and the policy is a plain cluster object you can GitOps. The one real gotcha — the thing that separates people who've shipped this from people who've only read about it — is that the **policy and the binding are two objects**, and the binding is what actually turns enforcement on and scopes it. Ship the policy alone and nothing happens.

When both objects exist and behave correctly, run the verifier.
