# Challenge 14 — Incident Playbook

**Difficulty:** Hard | **Type:** Verifier | **Est. Time:** 90 min

---

## Situation

```
02:34 AM. PagerDuty fires.

Falco alert: "Shell spawned in container payments/processor"
Audit log: SA 'processor-sa' listed secrets in namespace 'dojo-sec-incident' at 02:33:41Z
```

You're on-call. The `processor` deployment in `dojo-sec-incident` has been compromised. An attacker spawned a shell, used the pod's service account to list secrets, and planted a backdoor file.

You have 30 minutes. Follow PICERL:

| Step | Action | Verifier Check |
|------|--------|----------------|
| **P**repare | — (already done by being on-call) | — |
| **I**dentify | Record what was compromised | ConfigMap `incident-identified` |
| **C**ontain | Isolate the pod | NetworkPolicy `isolate-processor` |
| **E**radicate | Rotate compromised credentials | Secret annotation `dojo.incident/rotated=true` |
| **R**ecover | Restart the deployment clean | Deployment generation > 1 |
| **L**essons | Document root cause | ConfigMap `incident-rca` |

All 5 steps must be completed to earn the flag.

---

## Lab Setup

```bash
bash courses/course-38-redblue-security/challenges/14-incident-playbook/setup.sh
```

---

## Verifier

```bash
bash courses/course-38-redblue-security/challenges/14-incident-playbook/verify.sh
```

---

## What You'll Learn

- Incident response framework (PICERL)
- Using NetworkPolicies for emergency isolation
- Credential rotation under pressure
- Writing a root cause analysis in K8s terms
- Why automation (pre-built runbooks) is essential for 02:34 AM incidents
