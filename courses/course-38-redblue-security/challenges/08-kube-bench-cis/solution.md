# kube-bench CIS Hardening — Solution

## Reading the Results

```bash
kubectl get configmap kube-bench-results -n dojo-sec-cis -o jsonpath='{.data.output}'
```

This shows kube-bench output with PASS/FAIL results for CIS checks.

## Reading the Checklist

```bash
kubectl get configmap cis-checklist -n dojo-sec-cis -o jsonpath='{.data.checklist}'
```

Five checks to understand:
- 1.2.1 — API server: `--anonymous-auth=false`
- 1.2.7 — API server: `--authorization-mode=...RBAC...`
- 1.2.16 — API server: `--insecure-port=0`
- 4.2.1 — Kubelet: `authentication.anonymous.enabled: false`
- 4.2.2 — Kubelet: `authorization.mode: Webhook` (not AlwaysAllow)

## Why These Checks Matter

**1.2.1 anonymous-auth=false:**
Disabling anonymous auth means every request to the API server must be authenticated. Without this, an attacker can call read-only endpoints (like `/api/v1/pods`) without any credentials.

**1.2.16 insecure-port=0:**
The API server had an HTTP port (8080) in older versions. This disables it — all API access must use TLS.

**4.2.1 kubelet anonymous-auth=false:**
Each kubelet has its own API endpoint. If anonymous auth is enabled, attackers with network access can call it directly to list pods or even exec commands.

**4.2.2 kubelet authorization-mode:**
`AlwaysAllow` means every authenticated request to the kubelet is allowed. `Webhook` means it checks with the API server's RBAC.

## Run the Verifier

```bash
bash verify.sh
```

**Flag: `KUBE{cis_benchmark_level1_pass}`**

---

## Common FAQs

**Q: Some checks fail in kind — is that bad?**
A: Expected. Kind manages etcd permissions and certificates differently than production kubeadm clusters. The important checks (anonymous-auth, authorization-mode, insecure-port) pass in kind because those are configured correctly by default.

**Q: How do I actually FIX failing checks in production?**
A: Edit `/etc/kubernetes/manifests/kube-apiserver.yaml` on the control plane node and add/modify the failing flags. The kubelet is configured via `/var/lib/kubelet/config.yaml`. Restart is automatic when manifest files change (they're static pods).
