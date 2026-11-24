# SPIFFE Attestation — Solution

## Step 1: Verify SPIRE is Running

```bash
kubectl get pods -n dojo-sec-spiffe
# NAME              READY   STATUS    RESTARTS
# spire-server-0    1/1     Running   0
# spiffe-workload   1/1     Running   0
```

## Step 2: Get the Node UID

The parent ID for the workload entry must reference the SPIRE agent on a specific node:

```bash
NODE_UID=$(kubectl get node -o jsonpath='{.items[0].metadata.uid}')
echo "Node UID: $NODE_UID"
```

## Step 3: Register the Workload Entry

```bash
kubectl exec -n dojo-sec-spiffe spire-server-0 -- \
  /opt/spire/bin/spire-server entry create \
  -spiffeID spiffe://cluster.local/ns/dojo-sec-spiffe/sa/spiffe-sa \
  -parentID spiffe://cluster.local/spire/agent/k8s_psat/kube-dojo/$(kubectl get node -o jsonpath='{.items[0].metadata.uid}') \
  -selector k8s:ns:dojo-sec-spiffe \
  -selector k8s:sa:spiffe-sa
```

Output:
```
Entry ID         : abc123...
SPIFFE ID        : spiffe://cluster.local/ns/dojo-sec-spiffe/sa/spiffe-sa
Parent ID        : spiffe://cluster.local/spire/agent/k8s_psat/kube-dojo/<node-uid>
Revision         : 0
X509-SVID TTL    : default
JWT-SVID TTL     : default
Selector         : k8s:ns:dojo-sec-spiffe
Selector         : k8s:sa:spiffe-sa
```

## Step 4: Verify the Entry

```bash
kubectl exec -n dojo-sec-spiffe spire-server-0 -- \
  /opt/spire/bin/spire-server entry show
```

You should see the entry with SPIFFE ID `spiffe://cluster.local/ns/dojo-sec-spiffe/sa/spiffe-sa`.

## Step 5: Run the Verifier

```bash
bash verify.sh
```

**Flag: `KUBE{spiffe_svid_proves_workload_identity}`**

---

## What Happens After Registration

Once the entry exists:
1. The SPIRE Agent on the node polls the SPIRE Server and learns about the new entry
2. When `spiffe-workload` pod calls the Workload API socket (`/run/spire/sockets/agent.sock`), the agent:
   - Checks the pod's namespace (`dojo-sec-spiffe`) ✓ matches selector
   - Checks the pod's service account (`spiffe-sa`) ✓ matches selector
   - Issues an X.509-SVID for `spiffe://cluster.local/ns/dojo-sec-spiffe/sa/spiffe-sa`
3. The pod can now use that SVID for mTLS — proving its identity to other services

A rogue pod with a different SA or namespace will NOT match the selectors and will NOT receive this SVID.
