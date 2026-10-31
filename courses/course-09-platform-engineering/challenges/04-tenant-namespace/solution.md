# Solution — Provision a Tenant Namespace

Three manifests, applied once. The namespace and ServiceAccount already exist from setup.sh.

```yaml
# quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-a-quota
  namespace: dojo-tenant-a
spec:
  hard:
    pods: "10"
    cpu: "4"
    memory: 4Gi
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
```

```yaml
# limitrange.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: tenant-a-limits
  namespace: dojo-tenant-a
spec:
  limits:
    - type: Container
      default:
        cpu: 200m
        memory: 128Mi
      defaultRequest:
        cpu: 100m
        memory: 64Mi
      max:
        cpu: "2"
        memory: 2Gi
```

```yaml
# rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-operator-edit
  namespace: dojo-tenant-a
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
subjects:
  - kind: ServiceAccount
    name: tenant-operator
    namespace: dojo-tenant-a
```

Apply and verify:

```bash
kubectl apply -f quota.yaml -f limitrange.yaml -f rolebinding.yaml
bash courses/course-09-platform-engineering/challenges/04-tenant-namespace/verify.sh
```

## Why each piece matters

**ResourceQuota — the hard ceiling.** Without it, a tenant's pod crash-loop that spins up 1000 pods would exhaust the node's process table and affect every other tenant. The `pods` limit is the blunt instrument; `cpu`/`memory` quotas are the fine-grained controls. Important subtlety: if you set a ResourceQuota on a namespace, *every* pod admitted must have explicit requests/limits — the API server rejects pods without them. That's actually the desired behaviour (it forces good hygiene), but your LimitRange's `defaultRequest`/`default` fields are what make it seamless: pods with no resource fields get injected values automatically on admission.

**LimitRange — the admission default injector.** LimitRange does two things: it injects defaults for pods that omit resource fields (solving the ResourceQuota admission gate), and it enforces a `max` so no single container can claim the entire quota in one pod. The `max` field here is advisory guard-rail territory; real platforms often set it at 50–75% of the quota maximum.

**RoleBinding (not ClusterRoleBinding) — the blast-radius boundary.** Using a RoleBinding to bind a ClusterRole is intentional: it gives `edit` permissions only within `dojo-tenant-a`. The same `edit` ClusterRole bound cluster-wide via a ClusterRoleBinding would let the tenant modify resources in every namespace, including `kube-system`. The scope is entirely determined by whether you use RoleBinding or ClusterRoleBinding, not by the role itself.

## Attacker's view

If you bind `cluster-admin` as a ClusterRoleBinding "just for now," you've created a lateral-movement path. An attacker who compromises `tenant-operator`'s token can create a pod in any namespace with `hostPID: true` and escape to the node. The principle: grant the narrowest ClusterRole that works (view < edit < admin), and always use RoleBinding not ClusterRoleBinding unless you genuinely need cross-namespace scope.

## Hardening preview

Real multi-tenancy goes further:

- **Hierarchical Namespace Controller (HNC)** propagates RBAC from a parent namespace to children, letting you model org/team/service hierarchy without duplicating RoleBindings.
- **Kyverno or OPA Gatekeeper** can enforce that every new namespace has a matching ResourceQuota before the API server admits it.
- **NetworkPolicy** adds the data-plane isolation that RBAC cannot provide — RBAC stops API calls, NetworkPolicy stops pod-to-pod traffic.
