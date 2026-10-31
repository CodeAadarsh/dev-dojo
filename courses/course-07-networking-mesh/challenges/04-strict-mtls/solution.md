# Solution — Strict mTLS Enforcement

One manifest is all you need: a namespace-scoped `PeerAuthentication` named `default`.

```yaml
# peer-auth-strict.yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: dojo-mtls
spec:
  mtls:
    mode: STRICT
```

Apply it:

```bash
kubectl apply -f peer-auth-strict.yaml
bash courses/course-07-networking-mesh/challenges/04-strict-mtls/verify.sh
```

## Why each piece matters

**The name `default` is load-bearing.** Istio treats a `PeerAuthentication` named `default` in a namespace as the namespace-wide policy. A differently-named resource without a `selector` also works, but `default` is the conventional name and makes intent obvious — every operator scanning the namespace will immediately understand what it does.

**No `selector` = namespace-wide.** Adding a `spec.selector.matchLabels` turns this into a per-workload override. Leaving it empty means every pod in the namespace is governed by this policy, which is what you want as a default.

**`STRICT` vs `PERMISSIVE`.** In `PERMISSIVE` mode, the Istio sidecar (Envoy proxy) accepts both mTLS-encrypted traffic from other Envoy sidecars AND unencrypted plaintext from clients without a sidecar. `STRICT` rejects anything without a valid mTLS handshake. This matters because:
- In `PERMISSIVE`, a compromised pod that lacks a sidecar (or bypasses it via `hostNetwork: true`) can still talk to your service in plaintext.
- In `STRICT`, only pods enrolled in the mesh with a valid SPIFFE/X.509 identity can reach the service — the control-plane CA becomes your east-west firewall.

## Attacker's view

With `PERMISSIVE` still active, an attacker who pops a pod in an adjacent namespace can curl your service directly without presenting any cert:

```bash
# from a pod outside the mesh (no sidecar)
curl http://echo.dojo-mtls.svc.cluster.local/
# -> 200 OK  (attacker wins — no mTLS check)
```

After switching to `STRICT`:

```bash
# same curl from an unmeshed pod
curl http://echo.dojo-mtls.svc.cluster.local/
# -> connection reset / 503 (Envoy refuses plaintext)
```

**Hardening note.** `STRICT` at namespace level is step one. Follow it with an `AuthorizationPolicy` that allows only specific `principals` (SPIFFE IDs) to call each service — that's the mesh equivalent of a firewall allow-list and closes the "any pod in the mesh can call any other pod" gap.
