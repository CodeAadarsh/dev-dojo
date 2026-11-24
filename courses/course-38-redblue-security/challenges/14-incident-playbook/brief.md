# Incident Playbook — PICERL in Order

Your Falco alert just fired. Something is wrong in the cluster. The incident has started.

This challenge tests whether you know the incident response playbook — specifically the PICERL framework and the ORDER in which steps must be done. You can't recover before you contain. You can't eradicate before you identify.

A simulated attack has left traces in namespace `dojo-sec-incident`:
- A "malicious" pod running
- A suspicious ClusterRoleBinding
- A leaked credential secret

You must perform each step in the correct order, labeling your actions so the verifier can confirm you followed the playbook.

## PICERL Steps for This Challenge

| Step | Action | How to record it |
|------|--------|------------------|
| Identify | Label `malicious-pod` as identified | `kubectl label pod malicious-pod -n dojo-sec-incident dojo.incident/identified=true` |
| Contain | Label `malicious-pod` as contained | `kubectl label pod malicious-pod -n dojo-sec-incident dojo.incident/contained=true` |
| Eradicate | Delete the suspicious ClusterRoleBinding | `kubectl delete clusterrolebinding suspicious-crb` |
| Recover | Delete the leaked secret + create `rotated-creds` | See below |

## Recover Step

```bash
# Delete the leaked credential
kubectl delete secret leaked-creds -n dojo-sec-incident

# Create a rotated version (new value = recovered)
kubectl create secret generic rotated-creds \
  --from-literal=password="new-rotated-password-$(date +%s)" \
  -n dojo-sec-incident
```

## Rules of Engagement

- Namespace: `dojo-sec-incident`
- Perform steps in order: Identify → Contain → Eradicate → Recover
- Run verify.sh after all 4 steps
