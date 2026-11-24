# Audit Log Forensics

It's 11pm. Your pager fires: "Anomalous secret access in production cluster." You pull up the cluster audit logs and see a burst of activity that happened 6 hours ago — someone listed and read secrets in a namespace they shouldn't have been in.

The attacker is gone. But they always leave traces: the Kubernetes API server audit log records every API call — who made it, what they did, and what the response code was. If audit logging is configured correctly, you have a complete record.

In this challenge, we've simulated the attack aftermath. The attacker read a specific secret and embedded a flag inside it before disappearing. Your job is to follow the audit trail, identify what they accessed, and retrieve the flag.

## Mission

1. Read the simulated audit trail in ConfigMap `audit-trail` in namespace `dojo-sec-forensics`
2. Parse the log to find which secret the attacker read
3. Retrieve that secret and extract the `flag` field

## Why audit logs matter

Without audit logging, an attacker can pivot through your cluster, read credentials, and exfiltrate data with no record. With audit logging:

```
# Real K8s audit log entry (shortened):
{
  "verb": "get",
  "user": {"username": "system:serviceaccount:prod:default"},
  "objectRef": {"resource": "secrets", "name": "db-creds", "namespace": "prod"},
  "responseStatus": {"code": 200},
  "requestReceivedTimestamp": "2026-11-25T17:04:32Z"
}
```

Fields to look for during incident response:
- `verb`: what they did (`list`, `get`, `create`, `delete`)
- `user.username`: who did it (service account, user, or system component)
- `objectRef.resource` + `objectRef.name`: what they touched
- `responseStatus.code`: 200 means they succeeded; 403 means denied

## Target state

- Read the simulated audit trail: `kubectl get configmap audit-trail -n dojo-sec-forensics`
- Find the secret the attacker read (the verb `get` + resource `secrets`)
- Retrieve its `flag` key: `kubectl get secret <name> -n dojo-sec-forensics -o jsonpath='{.data.flag}' | base64 -d`
- Submit the flag
