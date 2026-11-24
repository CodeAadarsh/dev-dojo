# Solution — Admission Gauntlet

## Overview

Five Kyverno ClusterPolicies, one per attack pattern. Apply all five, verify they block their target, then create the evidence ConfigMap.

## Policy 1 — Block Privileged Containers

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged-containers
spec:
  validationFailureAction: Enforce
  rules:
  - name: no-privileged
    match:
      any:
      - resources:
          kinds: [Pod]
    validate:
      message: "Privileged containers are not allowed."
      pattern:
        spec:
          containers:
          - =(securityContext):
              =(privileged): "false"
```

Test:
```bash
kubectl apply --dry-run=server -f attack1-privileged.yaml
# → error: ... Privileged containers are not allowed.
```

## Policy 2 — Block hostPath Mounts

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-host-path
spec:
  validationFailureAction: Enforce
  rules:
  - name: no-hostpath
    match:
      any:
      - resources:
          kinds: [Pod]
    validate:
      message: "HostPath volumes are not allowed."
      deny:
        conditions:
          any:
          - key: "{{ request.object.spec.volumes[].hostPath | length(@) }}"
            operator: GreaterThan
            value: "0"
```

## Policy 3 — Require Non-Root

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-non-root
spec:
  validationFailureAction: Enforce
  rules:
  - name: no-root-user
    match:
      any:
      - resources:
          kinds: [Pod]
    validate:
      message: "Containers must not run as root (UID 0)."
      pattern:
        spec:
          containers:
          - securityContext:
              runAsNonRoot: true
```

## Policy 4 — Require Resource Limits

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-limits
spec:
  validationFailureAction: Enforce
  rules:
  - name: limits-required
    match:
      any:
      - resources:
          kinds: [Pod]
    validate:
      message: "CPU and memory limits are required."
      pattern:
        spec:
          containers:
          - resources:
              limits:
                cpu: "?*"
                memory: "?*"
```

## Policy 5 — Disallow :latest Tag

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Enforce
  rules:
  - name: no-latest
    match:
      any:
      - resources:
          kinds: [Pod]
    validate:
      message: "Images must not use the ':latest' tag. Pin to a specific digest or version."
      foreach:
      - list: "request.object.spec.containers"
        deny:
          conditions:
            any:
            - key: "{{ element.image }}"
              operator: Equals
              value: "*:latest"
            - key: "{{ element.image | contains(@, ':') }}"
              operator: Equals
              value: "false"
```

## Apply All Policies

```bash
kubectl apply -f policy1-privileged.yaml
kubectl apply -f policy2-hostpath.yaml
kubectl apply -f policy3-non-root.yaml
kubectl apply -f policy4-limits.yaml
kubectl apply -f policy5-latest.yaml

# Wait for policies to sync
kubectl wait --for=condition=Ready clusterpolicy --all --timeout=60s
```

## Verify Each Policy Blocks Its Attack

```bash
# 1. Privileged — should be rejected
kubectl apply --dry-run=server - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test
  namespace: dojo-sec-gauntlet
spec:
  containers:
  - name: c
    image: alpine:3.20
    securityContext:
      privileged: true
    command: ["sleep", "1"]
EOF
# Expected: Error from server: ... Privileged containers are not allowed.

# 2–5: similar pattern with the respective attack spec
```

## Record Evidence

```bash
kubectl create configmap policy-evidence \
  -n dojo-sec-gauntlet \
  --from-literal=privileged=blocked \
  --from-literal=hostpath=blocked \
  --from-literal=root-user=blocked \
  --from-literal=no-limits=blocked \
  --from-literal=latest-tag=blocked
```

**Flag:** `KUBE{five_policies_block_five_attacks}`

## Defense in Depth

Kyverno validates at admission time — before the pod is scheduled. But admission webhooks can be bypassed if:

- The webhook fails and `failurePolicy: Ignore` is set → always use `Enforce` or `Fail`
- The attacker has cluster-admin and can delete the ValidatingWebhookConfiguration
- The API server has `--disable-admission-plugins` set for that webhook

Always combine admission control with:
- `PodSecurity` admission (built-in PSA labels on namespaces)
- Runtime security (Falco, Tetragon)
- RBAC restricting who can create/delete ClusterPolicies
