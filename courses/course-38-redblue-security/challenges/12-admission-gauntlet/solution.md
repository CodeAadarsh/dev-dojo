# Admission Gauntlet — Solution

## OPA Policies (Attacks 1 & 2)

### ConstraintTemplate: Block Privileged

```yaml
# Save as block-privileged-template.yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: blockprivilegedcontainer
spec:
  crd:
    spec:
      names:
        kind: BlockPrivilegedContainer
  targets:
  - target: admission.k8s.gatekeeper.sh
    rego: |
      package blockprivilegedcontainer
      violation[{"msg": msg}] {
        container := input.review.object.spec.containers[_]
        container.securityContext.privileged == true
        msg := sprintf("Container '%v' must not be privileged", [container.name])
      }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: BlockPrivilegedContainer
metadata:
  name: block-privileged-gauntlet
spec:
  enforcementAction: deny
  match:
    kinds:
    - apiGroups: [""]
      kinds: ["Pod"]
    namespaces: ["dojo-sec-gauntlet"]
```

```bash
kubectl apply -f block-privileged-template.yaml
sleep 5  # wait for Gatekeeper to sync
```

### ConstraintTemplate: Block HostPath Root

```yaml
# Save as block-hostpath-template.yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: blockhostpathroot
spec:
  crd:
    spec:
      names:
        kind: BlockHostPathRoot
  targets:
  - target: admission.k8s.gatekeeper.sh
    rego: |
      package blockhostpathroot
      violation[{"msg": msg}] {
        volume := input.review.object.spec.volumes[_]
        volume.hostPath.path == "/"
        msg := "hostPath mount of '/' is not allowed — grants access to entire node filesystem"
      }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: BlockHostPathRoot
metadata:
  name: block-hostpath-root-gauntlet
spec:
  enforcementAction: deny
  match:
    kinds:
    - apiGroups: [""]
      kinds: ["Pod"]
    namespaces: ["dojo-sec-gauntlet"]
```

---

## Kyverno Policies (Attacks 3, 4, 5)

```yaml
# Save as kyverno-gauntlet-policies.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-limits
spec:
  validationFailureAction: Enforce
  rules:
  - name: check-container-limits
    match:
      any:
      - resources:
          kinds: [Pod]
          namespaces: [dojo-sec-gauntlet]
    validate:
      message: "All containers must have CPU and memory limits."
      pattern:
        spec:
          containers:
          - resources:
              limits:
                cpu: "?*"
                memory: "?*"
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: no-untagged-images
spec:
  validationFailureAction: Enforce
  rules:
  - name: require-image-tag
    match:
      any:
      - resources:
          kinds: [Pod]
          namespaces: [dojo-sec-gauntlet]
    validate:
      message: "Images must have a specific tag (not untagged or :latest)."
      foreach:
      - list: "request.object.spec.containers"
        deny:
          conditions:
            any:
            - key: "{{ element.image }}"
              operator: NotContains
              value: ":"
            - key: "{{ element.image }}"
              operator: Contains
              value: ":latest"
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: block-admin-sa
spec:
  validationFailureAction: Enforce
  rules:
  - name: block-dojo-sec-gauntlet-admin-sa
    match:
      any:
      - resources:
          kinds: [Pod]
          namespaces: [dojo-sec-gauntlet]
    validate:
      message: "Service account 'dojo-sec-gauntlet-admin' is not allowed for pods."
      pattern:
        spec:
          =(serviceAccountName): "!dojo-sec-gauntlet-admin"
```

```bash
kubectl apply -f kyverno-gauntlet-policies.yaml
sleep 10  # wait for Kyverno webhook to sync
```

## Running the Verifier

```bash
bash verify.sh
```

**Flag: `KUBE{five_policies_block_five_attacks}`**
