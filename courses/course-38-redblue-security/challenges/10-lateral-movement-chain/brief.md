# Challenge 10 — Lateral Movement Chain

**Difficulty:** Hard | **Type:** Discovery | **Est. Time:** 60 min

---

## Situation

You have a foothold. Pod `entry-point` in namespace `dojo-sec-lateral-a` is compromised. Its service account token is in your hands.

But the flag isn't here. It's three hops away.

Execute the full lateral movement chain:

```
dojo-sec-lateral-a (entry-point)
         │  steal SA token
         ▼
dojo-sec-lateral-b  (pivot: use stolen token to list secrets)
         │  steal hop-two-token
         ▼
dojo-sec-lateral-c  (final: read the flag ConfigMap)
```

Each namespace has its own RBAC scope. You'll need to chain stolen service account tokens across namespaces to reach the prize.

---

## Lab Setup

```bash
bash courses/course-38-redblue-security/challenges/10-lateral-movement-chain/setup.sh
```

---

## Your Goal

Read the flag from ConfigMap `final-flag` in namespace `dojo-sec-lateral-c`.

```bash
kubectl get configmap final-flag -n dojo-sec-lateral-c -o jsonpath='{.data.flag}'
```

The flag value is `KUBE{three_hops_to_node_compromise}`.

---

## Rules of Engagement

You must traverse all three hops — do not use cluster-admin or your default kubeconfig to skip to namespace C. The point is to understand the token-chaining technique.

Start from inside the pod:

```bash
kubectl exec -n dojo-sec-lateral-a entry-point -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
```

---

## What You'll Learn

- How compromised service account tokens can be used cross-namespace
- Using `kubectl --token` and `--server` flags with stolen credentials
- Why RBAC scope matters: least privilege across namespaces
- Audit log patterns that detect cross-namespace token pivoting
