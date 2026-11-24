# Audit Log Forensics — Solution

## The Investigation

The flag is stored in the secret `attacker-secret` in namespace `dojo-sec-forensics`. The audit trail shows the attacker read this secret.

### Step 1: Read the Simulated Audit Trail

```bash
kubectl get configmap audit-trail -n dojo-sec-forensics -o jsonpath='{.data.log}'
```

Output (each line is one audit event):

```json
{"timestamp":"2026-11-25T17:04:30Z","verb":"list",...,"objectRef":{"resource":"pods",...},...}
{"timestamp":"2026-11-25T17:04:32Z","verb":"list",...,"objectRef":{"resource":"secrets",...},...}
{"timestamp":"2026-11-25T17:04:35Z","verb":"get",...,"objectRef":{"resource":"secrets","name":"app-config"},...}
{"timestamp":"2026-11-25T17:04:38Z","verb":"get",...,"objectRef":{"resource":"secrets","name":"attacker-secret"},...}
{"timestamp":"2026-11-25T17:04:42Z","verb":"create",...,"objectRef":{"resource":"pods","name":"exfil-pod"},...}
{"timestamp":"2026-11-25T17:04:45Z","verb":"delete",...,"objectRef":{"resource":"pods","name":"exfil-pod"},...}
```

### Step 2: Identify the Timeline

Reading the events chronologically:

1. **17:04:30** — attacker listed all pods (reconnaissance)
2. **17:04:32** — attacker listed all secrets (finding targets)
3. **17:04:35** — attacker read `app-config` (decoy — no useful data)
4. **17:04:38** — attacker read **`attacker-secret`** ← this is what they were after
5. **17:04:42** — attacker created `exfil-pod` (to exfiltrate the data)
6. **17:04:45** — attacker deleted `exfil-pod` (cleaning up)

The secret `attacker-secret` is the target. It has a `flag` data field.

### Step 3: Retrieve the Secret

```bash
kubectl get secret attacker-secret -n dojo-sec-forensics
```

Output:
```
NAME              TYPE     DATA   AGE
attacker-secret   Opaque   3      5m
```

### Step 4: Decode the Flag

```bash
kubectl get secret attacker-secret -n dojo-sec-forensics \
  -o jsonpath='{.data.flag}' | base64 -d
```

**Flag: `KUBE{audit_logs_never_lie}`**

---

## Why This Works

The Kubernetes API server audit log records every API call — who made it, what they touched, and when. Even if the attacker deleted their exfil pod and their traces, the audit log entries for the secret reads cannot be deleted (the attacker doesn't have access to the audit log files themselves, only the API objects).

In a real incident, you'd parse the actual audit log file (often at `/var/log/apiserver/audit.log` on the control plane node). The analysis technique is identical:
1. Filter for `verb: get` or `verb: list` on `resource: secrets`
2. Look for unusual usernames (unexpected service accounts, unknown users)
3. Cross-reference timestamps to build the attack timeline
4. Retrieve the accessed secrets to understand the blast radius

---

## Defenses

1. **Audit log alerting**: Set up alerts for bulk secret reads (`list` verb on `secrets` resource)
2. **RBAC least privilege**: The default SA should NOT have permission to list secrets — give each application only the specific secrets it needs
3. **Network segmentation**: The exfil pod created at 17:04:42 could have been blocked by a default-deny egress NetworkPolicy
4. **Falco**: A rule matching `evt.type = connect and fd.sip not in (allowed_ips)` from the exfil pod would have fired an alert
