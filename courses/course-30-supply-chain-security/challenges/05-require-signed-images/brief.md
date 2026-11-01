# Require Signed Images with Kyverno

Security scans your registry and flags a container running a two-year-old image that was pulled from Docker Hub with no digest pin and no provenance record. When you ask the team how they know the image wasn't tampered with in transit, the answer is silence. The root problem: nothing in the admission path checked whether images were signed before they were admitted.

Admission control is the enforcement point where you can make signed images a hard cluster requirement rather than a soft guideline. Kyverno's `verifyImages` rule calls the cosign verification logic directly inside the admission webhook — a Pod with an unsigned image is rejected at the API server before the scheduler ever sees it.

## Prerequisites

**Kyverno** must be installed in the cluster:

```bash
# Install Kyverno (latest stable)
kubectl create -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml

# Wait for Kyverno pods to be ready (may take 60-90 seconds)
kubectl -n kyverno wait pod --all --for=condition=Ready --timeout=120s

# Confirm
kubectl get crd clusterpolicies.kyverno.io
```

## Setup

```bash
bash courses/course-30-supply-chain-security/challenges/05-require-signed-images/setup.sh
```

Creates namespace `dojo-supplychain` and confirms Kyverno is detected.

## Mission

Author a `ClusterPolicy` named **`require-signed-images`** in **Enforce** mode with at least one `verifyImages` rule that applies to pods in the `dojo-supplychain` namespace.

### Required policy shape

The verifier checks these four things via `kubectl`:

| Check | Expected value |
|-------|----------------|
| `kubectl get clusterpolicy require-signed-images` | resource exists |
| `.spec.validationFailureAction` | `"Enforce"` |
| `.spec.rules[*].verifyImages` | field present (non-empty) |
| `.spec.rules[*]` or `.spec.rules[*].match` | references namespace `dojo-supplychain` |

A minimal skeleton:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-images
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: verify-image-signature
      match:
        resources:
          kinds:
            - Pod
          namespaces:
            - dojo-supplychain
      verifyImages:
        - imageReferences:
            - "*"
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      <your cosign.pub contents here>
                      -----END PUBLIC KEY-----
```

For the `publicKeys` value: paste the contents of `cosign.pub` from Challenge 04 (or generate a new key pair with `cosign generate-key-pair`). The verifier checks policy **structure**, not that images in the registry are actually signed — so any valid PEM public key satisfies the check.

## Why `background: false` matters

Without it, Kyverno's background controller would attempt to verify all existing pods on its schedule. Since none of them have cosign signatures in your dojo registry, you'd see a flood of policy violation events for every running pod in the cluster. Setting `background: false` limits enforcement to new admission requests — exactly what you want in a lab and what you'd enable carefully in stages in production.

## Why this matters

A signed-image enforcement policy closes the gap between "we sign our images" and "unsigned images cannot run." The signing convention at build time is only half the control. Without the admission gate, a developer can still `kubectl run nginx:latest --image=nginx:latest` and it works. With the gate in Enforce mode, that admission request is rejected — the gap is closed at the API server boundary, not by hope.

## Verify

```bash
bash courses/course-30-supply-chain-security/challenges/05-require-signed-images/verify.sh
```
