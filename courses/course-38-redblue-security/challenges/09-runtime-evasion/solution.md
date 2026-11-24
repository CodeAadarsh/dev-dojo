# Runtime Evasion — Solution

## The Solution

```bash
kubectl get configmap evasion-reward -n dojo-sec-evasion -o jsonpath='{.data.flag}'
```

**Flag: `KUBE{falco_rules_have_blind_spots}`**

---

## Why This Is the Answer

Falco's "Terminal shell in container" rule requires a process (`sh`, `bash`) to execute inside a container. That means:
- A syscall: `execve("/bin/sh", ...)`
- In a container namespace (container.id != host)

When you run `kubectl get configmap`, you're calling the Kubernetes API server over HTTPS. The API server reads the data from etcd and returns it to you. No container is involved. No syscall in a container fires. Falco never alerts.

## Real-World Implications

```
Attacker with stolen kubeconfig on their laptop:
  kubectl get secrets --all-namespaces    ← No Falco alert
  kubectl get secret db-creds -o yaml     ← No Falco alert
  
Attacker who exec-ed into a pod:
  kubectl exec -it pod -- /bin/sh         ← Falco FIRES: "Terminal shell in container"
```

The blind spot: **exfiltration via kubectl API reads is invisible to Falco**.

## The Complete Detection Stack

To catch both:
1. **Falco**: catches container-level activity (shells, file reads, network calls from inside containers)
2. **Kubernetes audit log**: catches API-level activity (kubectl reads, writes, execs)

Both are needed. Neither is sufficient alone.

## How to Catch API-Level Exfiltration

Audit log policy to catch bulk secret reads:

```yaml
# audit-policy.yaml
- level: Metadata
  verbs: [get, list]
  resources:
  - group: ""
    resources: [secrets]
```

Then alert on:
- More than N secrets read per minute by a single identity
- Cross-namespace secret reads by a SA that shouldn't be doing that
- Secret reads by a kubeconfig token from an unexpected IP address
