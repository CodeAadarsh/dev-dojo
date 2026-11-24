# Runtime Evasion

Falco is running. Falco is watching. Every shell spawn, every sensitive file read, every package install — Falco sees it.

Except when it doesn't.

Falco monitors syscalls inside containers. But Kubernetes has an API. And kubectl calls that API from OUTSIDE the containers — over HTTPS to the API server. No container process, no syscall in a container, no Falco alert.

Your mission is to retrieve the flag from a ConfigMap in this namespace **without execing into any container** — because exec WOULD trigger Falco's "Terminal shell in container" rule. Use Kubernetes API calls only.

## Why This Is a Real Attack Technique

A sophisticated attacker who knows Falco is deployed will avoid `kubectl exec` entirely. Instead:
- `kubectl cp` to copy files in/out of containers without spawning a shell
- Direct Kubernetes API calls to read resources (ConfigMaps, Secrets) without touching a container
- Creating a new Job that does the work and exits (Job's container runs briefly, Falco fires, but the data is already in the Job's log which the attacker reads via `kubectl logs` from outside)

This technique exfiltrates data from the cluster without ever spawning a persistent shell — greatly limiting Falco's ability to alert in time.

## Mission

1. Find the flag in the ConfigMap `evasion-reward` in namespace `dojo-sec-evasion`
2. Retrieve it using ONLY kubectl API calls — no `kubectl exec`, no `kubectl attach`
3. The flag is directly readable via the Kubernetes API — no container interaction needed

## Why This Matters

Falco is powerful but it has scope limitations:
- It sees: syscalls INSIDE running containers
- It doesn't see: `kubectl get secret`, `kubectl logs`, `kubectl cp` FROM outside the cluster
- These API calls are recorded in the **Kubernetes audit log** instead (not Falco's domain)

## Rules of Engagement

- Namespace: `dojo-sec-evasion`
- Do NOT use `kubectl exec` or `kubectl attach`
- The flag is in a ConfigMap — readable directly via kubectl API
- No verify.sh needed — read it and submit

## Hint

```bash
kubectl get configmap evasion-reward -n dojo-sec-evasion -o jsonpath='{.data.flag}'
```
