# Solution — Incident Playbook

## Overview

PICERL is a structured incident response framework. Each step has a concrete K8s action.

## I — Identify

Read the evidence:
```bash
# Review the Falco alert
kubectl get configmap falco-alert -n dojo-sec-incident -o jsonpath='{.data.alert}' | python3 -m json.tool

# Review the audit trail
kubectl get configmap audit-trail -n dojo-sec-incident -o jsonpath='{.data.audit_entries}'

# Check what the attacker planted
kubectl exec -n dojo-sec-incident deploy/processor -- ls /tmp/
# → attacker-backdoor
```

Record your finding:
```bash
kubectl create configmap incident-identified \
  -n dojo-sec-incident \
  --from-literal=compromised_resource=processor \
  --from-literal=attack_vector=sa_token_misuse \
  --from-literal=data_accessed=payment-db-creds
```

## C — Contain

Apply a deny-all NetworkPolicy to isolate the compromised pod:

```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: isolate-processor
  namespace: dojo-sec-incident
spec:
  podSelector:
    matchLabels:
      app: processor
  policyTypes:
  - Ingress
  - Egress
EOF
```

This immediately cuts off all inbound and outbound traffic to processor pods. The attacker's reverse shell dies. The pod can no longer exfiltrate data.

Verify:
```bash
kubectl get networkpolicy isolate-processor -n dojo-sec-incident
```

## E — Eradicate

Rotate the compromised credentials:
```bash
# In a real incident: regenerate the actual database password and update the secret
# For this exercise: annotate it as rotated
kubectl annotate secret payment-db-creds \
  dojo.incident/rotated=true \
  -n dojo-sec-incident

# Revoke the compromised SA token (tokens issued before this point are invalidated
# when the SA is deleted and recreated)
kubectl delete serviceaccount processor-sa -n dojo-sec-incident
kubectl create serviceaccount processor-sa -n dojo-sec-incident
```

Also revoke the RBAC that gave the SA too much access:
```bash
kubectl delete rolebinding processor-secret-access -n dojo-sec-incident
```

## R — Recover

Restart the deployment with a clean pod (removes the backdoor file from the container layer):
```bash
kubectl rollout restart deployment processor -n dojo-sec-incident
kubectl rollout status deployment processor -n dojo-sec-incident
```

Verify generation > 1:
```bash
kubectl get deployment processor -n dojo-sec-incident -o jsonpath='{.metadata.generation}'
```

## L — Lessons Learned

Document root cause and remediation:
```bash
kubectl create configmap incident-rca \
  -n dojo-sec-incident \
  --from-literal=root_cause=compromised_sa_token \
  --from-literal=contributing_factor_1=overpermissioned_sa_role \
  --from-literal=contributing_factor_2=no_network_policy \
  --from-literal=contributing_factor_3=no_falco_alert_routing \
  --from-literal=remediation_1=least_privilege_rbac \
  --from-literal=remediation_2=deny_all_network_policy_by_default \
  --from-literal=remediation_3=falco_to_pagerduty_integration
```

**Flag:** `KUBE{detect_contain_recover_in_order}`

## Post-Incident Hardening

```bash
# 1. Remove the overpermissioned role (processor shouldn't list all secrets)
kubectl patch role secret-lister -n dojo-sec-incident --type=json \
  -p='[{"op":"replace","path":"/rules/0/verbs","value":["get"]}]'
# → Only allow GET on specific secret names, not LIST

# 2. Apply default-deny NetworkPolicy to the namespace
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: dojo-sec-incident
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

# 3. Use short-lived projected tokens (1h max)
# (configure in the deployment spec)

# 4. Enable audit log streaming to SIEM
# kubectl apply -f audit-policy.yaml (send all secret access to Splunk/Datadog)
```

## Why PICERL Order Matters

**Identify before Contain**: If you isolate before understanding the full scope, you may cut off legitimate services or miss other compromised pods.

**Contain before Eradicate**: Rotating credentials while the attacker still has network access is pointless — they'll just re-steal them.

**Eradicate before Recover**: Restarting without revoking the token leaves the attack vector open.

**All before Lessons**: The RCA is only accurate once you understand the full timeline.
