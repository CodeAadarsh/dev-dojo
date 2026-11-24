# Incident Playbook — Solution

## The Four Steps

### Step 1: IDENTIFY

```bash
kubectl label pod malicious-pod -n dojo-sec-incident dojo.incident/identified=true
# pod/malicious-pod labeled
```

### Step 2: CONTAIN

```bash
kubectl label pod malicious-pod -n dojo-sec-incident dojo.incident/contained=true
# pod/malicious-pod labeled
```

(In a real incident, containment also includes: NetworkPolicy isolation, cordoning the node, disabling egress. Here the label simulates recording that you've done this.)

### Step 3: ERADICATE

```bash
# Remove the backdoor ClusterRoleBinding the attacker planted
kubectl delete clusterrolebinding suspicious-crb
# clusterrolebinding.rbac.authorization.k8s.io "suspicious-crb" deleted
```

### Step 4: RECOVER

```bash
# Delete the leaked credentials
kubectl delete secret leaked-creds -n dojo-sec-incident

# Create a new rotated credential
kubectl create secret generic rotated-creds \
  --from-literal=password="new-rotated-password-$(date +%s)" \
  -n dojo-sec-incident
```

## Run the Verifier

```bash
bash verify.sh
```

**Flag: `KUBE{detect_contain_recover_in_order}`**

---

## Why Order Matters

The PICERL order is not arbitrary:
- **Identify before Contain**: You can't contain what you haven't identified — you might contain the wrong thing
- **Contain before Eradicate**: Containing limits the blast radius while you do the cleanup — if you delete things before containing, the attacker may have already pivoted
- **Eradicate before Recover**: If you recover (restore service) before eradicating the attacker's backdoors, you're just re-exposing the same system to the same attacker
- **Recover before Learn**: Learn while the incident is fresh, but only after the system is clean

The flag name `KUBE{detect_contain_recover_in_order}` captures this: order matters.
