# Solution — Who Can Read Secrets?

The flag is `KUBE{enumerate_rbac_to_find_the_reader}`, and the identity that can read it is **`app-b`** (scoped by `resourceNames` to `payments-api-key`).

## Path 1 — sweep every (account × secret) pair

The authoritative answer comes from the API server's own authorizer, via `auth can-i --as`. Sweep the one Secret that matters across all three accounts:

```bash
NS=dojo-secrets
for sa in app-a app-b app-c; do
  printf '%-6s ' "$sa"
  kubectl -n "$NS" auth can-i get secret/payments-api-key \
    --as=system:serviceaccount:$NS:$sa
done
# app-a  no
# app-b  yes
# app-c  no
```

`app-b` is the reader. Now spend that identity to read the flag:

```bash
kubectl -n dojo-secrets get secret payments-api-key \
  -o jsonpath='{.data.FLAG}' \
  --as=system:serviceaccount:dojo-secrets:app-b | base64 -d; echo
# -> KUBE{enumerate_rbac_to_find_the_reader}
```

If you prefer a full matrix (every account against every Secret):

```bash
for sa in app-a app-b app-c; do
  for sec in payments-api-key telemetry-token frontend-config; do
    printf '%-6s %-18s ' "$sa" "$sec"
    kubectl -n dojo-secrets auth can-i get secret/$sec \
      --as=system:serviceaccount:dojo-secrets:$sa
  done
done
```

Each account answers `yes` to exactly one Secret — that is the `resourceNames` scoping at work.

## Path 2 — list each account's rights

```bash
kubectl -n dojo-secrets auth can-i --list \
  --as=system:serviceaccount:dojo-secrets:app-b
```

The key column is **Resource Names**:

```
Resources   Non-Resource URLs   Resource Names        Verbs
secrets     []                  [payments-api-key]    [get]
...
```

That `[payments-api-key]` is the tell. Run the same `--list` for `app-a` and `app-c` and you'll see `[telemetry-token]` and `[frontend-config]` respectively — proof that the scoping is per-Secret, and the reason a plain `auth can-i list secrets` would return `no` for all three.

## Path 3 — read the Roles directly

```bash
kubectl -n dojo-secrets get role -o yaml | grep -A5 resourceNames
```

Match each `resourceNames: [...]` to its `RoleBinding` subject to build the map by hand. Slower and error-prone the moment ClusterRoles or aggregated roles enter the picture — which is exactly why `auth can-i --as` is the tool you reach for first.

## The attacker's view

An attacker who lands in a pod running as `app-b` doesn't need to know which Secret they can read — they enumerate it from inside the pod with the mounted token, the same way you did with `--as`:

```bash
# inside the app-b pod
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -sk -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/apis/authorization.k8s.io/v1/selfsubjectrulesreviews \
  -X POST -H 'Content-Type: application/json' \
  -d '{"spec":{"namespace":"dojo-secrets"}}'
```

`SelfSubjectRulesReview` is exactly what `kubectl auth can-i --list` calls — it hands the attacker a map of what the stolen identity can reach.

## The fix

- **`resourceNames` is the right idea** — keep it. The lesson here is operational: because `list` is denied, naive "who can read secrets" checks that only test `list` under-report exposure. Your audit must test `get` with specific `resourceNames`.
- **Mount the token only where needed.** Set `automountServiceAccountToken: false` on ServiceAccounts and Pods that never call the API, so a compromised `app-b` pod has no token to enumerate with in the first place.
- **Rotate and alarm.** Treat any Secret that more than one identity can `get` as a review item, and alert on new bindings that grant `get`/`list` on `secrets`.
