# SPIFFE Attestation — Cryptographic Workload Identity

Two services talk to each other over TLS. The TLS is encrypted. But `payments-api` has no way to verify that the caller is actually `frontend` and not a rogue pod the attacker deployed.

SPIFFE/SPIRE gives every workload a cryptographic identity — an SVID (SPIFFE Verifiable Identity Document). The SVID is a short-lived X.509 certificate containing the workload's SPIFFE ID (`spiffe://cluster.local/ns/app/sa/frontend-sa`). No pod can fake another pod's SPIFFE ID — the SVID is issued by the SPIRE Server after verifying the pod's actual namespace and service account.

In this challenge, SPIRE is deployed. You'll register a workload and verify it gets the correct SVID.

## Mission

1. Check that SPIRE server and agent are running in namespace `dojo-sec-spiffe`
2. Register a workload entry for pod `spiffe-workload` in namespace `dojo-sec-spiffe`:
   - SPIFFE ID: `spiffe://cluster.local/ns/dojo-sec-spiffe/sa/spiffe-sa`
   - Selector: `k8s:ns:dojo-sec-spiffe` and `k8s:sa:spiffe-sa`
3. Verify the SVID is issued correctly
4. Run the verifier — it checks the registration entry exists and outputs the flag

## Commands

```bash
# Register the workload
kubectl exec -n dojo-sec-spiffe spire-server-0 -- \
  /opt/spire/bin/spire-server entry create \
  -spiffeID spiffe://cluster.local/ns/dojo-sec-spiffe/sa/spiffe-sa \
  -parentID spiffe://cluster.local/spire/agent/k8s_psat/kube-dojo/$(kubectl get node -o jsonpath='{.items[0].metadata.uid}') \
  -selector k8s:ns:dojo-sec-spiffe \
  -selector k8s:sa:spiffe-sa

# Verify entries
kubectl exec -n dojo-sec-spiffe spire-server-0 -- \
  /opt/spire/bin/spire-server entry show
```

## Rules of Engagement

- Namespace: `dojo-sec-spiffe`
- SPIRE server: `spire-server-0` (StatefulSet pod)
- SPIRE agent: runs as DaemonSet
- After registering, run: `bash verify.sh`
