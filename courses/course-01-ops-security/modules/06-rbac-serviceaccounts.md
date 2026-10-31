# RBAC & ServiceAccounts

> **Module 06 · Course 01** — Authentication asks *"who are you?"*. Authorization asks *"are you allowed to do that?"*. Kubernetes RBAC is the second question, and it's where most real clusters quietly leak privilege. This module is about reasoning through RBAC precisely enough to grant exactly what's needed and catch the over-grants before an auditor (or an attacker) does.

You already apply manifests with a kubeconfig that's effectively cluster-admin. That's fine in a dojo. In production the interesting question is what happens when the identity is a compromised pod, a CI ServiceAccount, or a junior engineer's token — and whether that identity can escalate. That's what we sharpen here.

---

## The four nouns, and the one rule that ties them together

RBAC in Kubernetes is four object types and a single composition rule:

| Object | Scope | Answers |
|--------|-------|---------|
| `Role` | one namespace | *what* actions on *which* resources (namespaced) |
| `ClusterRole` | whole cluster | *what* actions — on namespaced resources cluster-wide, OR on cluster-scoped resources (nodes, PVs, namespaces) |
| `RoleBinding` | one namespace | grants a Role **or** a ClusterRole *to subjects, inside this namespace* |
| `ClusterRoleBinding` | whole cluster | grants a ClusterRole *to subjects, everywhere* |

The rule: **a binding attaches a (Cluster)Role to subjects.** Roles/ClusterRoles are pure permission sets — inert until a binding references them. Nothing is denied explicitly; RBAC is purely additive (there are no deny rules), and permissions are the **union** of every binding that applies to you.

```
          defines permissions                    attaches them to identities
   ┌────────────────────────┐              ┌──────────────────────────────────┐
   │  Role / ClusterRole     │◀────────────│  RoleBinding / ClusterRoleBinding │
   │  (verbs on resources)   │   roleRef    │  (subjects: who)                  │
   └────────────────────────┘              └──────────────────────────────────┘
                                                        │
                              ┌─────────────────────────┼─────────────────────────┐
                              ▼                          ▼                         ▼
                           User                       Group                 ServiceAccount
                        (external IdP,            (external IdP,          (in-cluster identity,
                         client cert CN)           cert O= / OIDC)         has a token)
```

### The combination that trips people up

A `RoleBinding` can reference a **ClusterRole**. This is the single most useful (and most misunderstood) RBAC pattern:

```
RoleBinding (ns=dojo-rbac) ──roleRef──▶ ClusterRole "view"
```

This grants the *permissions defined in* the ClusterRole `view`, but **scoped to `dojo-rbac` only**. You define a reusable permission set once as a ClusterRole, then grant it namespace-by-namespace with RoleBindings. The reverse — a `ClusterRoleBinding` to that same ClusterRole — grants `view` across **every** namespace. Same ClusterRole, wildly different blast radius depending on the binding type.

> **The one combination that doesn't exist:** a `RoleBinding` cannot reference a `Role` in a *different* namespace, and a `ClusterRoleBinding` cannot reference a (namespaced) `Role`. `roleRef` is immutable after creation — to change which role a binding points at, delete and recreate it.

---

## Verbs and resources — the grammar of a rule

A rule is `apiGroups` × `resources` × `verbs` (optionally narrowed by `resourceNames`):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: dojo-rbac
  name: pod-reader
rules:
  - apiGroups: [""]                 # "" = the core API group (pods, services, configmaps…)
    resources: ["pods", "pods/log"] # subresources are their own resource string
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list"]
    resourceNames: ["web"]          # narrow to a single named object
```

Things worth internalizing:

- The core group is the empty string `""`. `apps`, `batch`, `rbac.authorization.k8s.io`, `networking.k8s.io` are separate groups — a rule only matches resources in the groups it names.
- **Subresources are distinct resources.** `pods/log`, `pods/exec`, `pods/portforward` are separate from `pods`. Granting `get pods` does **not** grant `kubectl logs` or `kubectl exec` — those need `pods/log` and `pods/exec`. This asymmetry is a common source of "why can't my debugger see logs?" tickets.
- The write verbs are `create`, `update`, `patch`, `delete`, `deletecollection`. The read verbs are `get`, `list`, `watch`. `list` leaks object *bodies*, not just names — granting `list secrets` is granting `get secrets` for the whole namespace.
- `resourceNames` can restrict `get`/`update`/`patch`/`delete` to named objects, but it **cannot** restrict `list`, `watch`, `create`, or `deletecollection` (you can't filter a list by name you don't know yet, and you can't name a thing before it exists).

Two more that cost people an afternoon each:

- **The apiGroup is the group, not the version.** In a rule you write `apiGroups: ["apps"]`, never `apps/v1`. A `Deployment` lives in `apps`, but a `Pod`/`Service`/`ConfigMap` lives in the core group `""`, and an `Ingress` lives in `networking.k8s.io`. Put a resource in the wrong group and the rule simply never matches — with **no error**, because RBAC rules aren't validated against the discovery API. The grant just silently does nothing.
- **CRDs need their own rules.** A ClusterRole that says `resources: ["*"]`, `apiGroups: [""]` does **not** cover your Custom Resources — they're in their own apiGroup (`monitoring.coreos.com`, `argoproj.io`, …). The built-in `admin`/`edit` ClusterRoles don't grant CRDs either. This is why "I'm cluster-admin in this namespace but can't touch the `PrometheusRule`" happens.

---

## ServiceAccounts & bound tokens — identity for pods

Human users are **not** Kubernetes objects — they come from an external authenticator (client certs, OIDC, an IdP) and Kubernetes only sees the resulting username/groups. **ServiceAccounts**, by contrast, are real namespaced objects and are the identity *workloads* run as.

Every pod runs as a ServiceAccount (`default` in its namespace unless you set `spec.serviceAccountName`). Since Kubernetes 1.22+ the token mounted into the pod is a **projected, bound** token, not the legacy forever-valid Secret token:

```
┌─ pod ──────────────────────────────────────────────────────────┐
│  spec.serviceAccountName: deployer                              │
│                                                                 │
│  /var/run/secrets/kubernetes.io/serviceaccount/                 │
│     ├── token        ← short-lived JWT, bound to THIS pod       │
│     │                  (audience=api, expires ~1h, auto-rotated)│
│     ├── ca.crt       ← API server CA to trust                   │
│     └── namespace    ← the pod's namespace                      │
└─────────────────────────────────────────────────────────────────┘
```

Why "bound" matters: the modern token is audience-scoped and tied to the pod's lifetime, so if it leaks it expires in ~an hour and is useless against a different audience — versus the legacy `kubernetes.io/service-account-token` Secret, which was a long-lived bearer token that, if exfiltrated, worked forever. The kubelet requests the token via the **TokenRequest API** and rotates it in place.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: deployer
  namespace: dojo-rbac
automountServiceAccountToken: false   # turn OFF for pods that never call the API
```

> **Default to no token.** A pod that never talks to the API server has no business carrying a credential an attacker can steal. Set `automountServiceAccountToken: false` on the ServiceAccount (or per-pod in `spec`). If you've mounted a token into a workload that doesn't need it, you've handed an attacker who lands in that container a ready-made cluster credential.

Bind permissions to the ServiceAccount exactly like any other subject:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: deployer-can-manage-deploys
  namespace: dojo-rbac
subjects:
  - kind: ServiceAccount
    name: deployer
    namespace: dojo-rbac
roleRef:
  kind: Role
  name: deployment-manager
  apiGroup: rbac.authorization.k8s.io
```

A ServiceAccount's username is `system:serviceaccount:<ns>:<name>` and it's a member of the groups `system:serviceaccounts` and `system:serviceaccounts:<ns>` — useful to know when you read audit logs or write `--as`.

One subtlety that routinely breaks bindings: the `subjects[].namespace` field is **mandatory** for a `ServiceAccount` subject and must name the SA's *home* namespace — even inside a `ClusterRoleBinding`, and even when the RoleBinding lives in a different namespace than the SA. Omit it and the binding is accepted but matches *nothing*, so the SA silently has no permissions. Contrast with `User`/`Group` subjects, which have no namespace (they're cluster-global identities) — adding one there is equally silently wrong.

---

## `kubectl auth can-i` and `--as` impersonation — test before you trust

Never reason about an RBAC grant in your head and call it done. Ask the API server:

```bash
kubectl auth can-i create deployments -n dojo-rbac          # answers for YOU
kubectl auth can-i '*' '*'                                  # am I effectively admin?
kubectl auth can-i list secrets -n kube-system
```

The power move is `--as`, which impersonates another subject (you need the `impersonate` verb, which cluster-admin has) so you can verify *their* access without ever logging in as them:

```bash
# Can the 'deployer' ServiceAccount read secrets? (it shouldn't)
kubectl auth can-i get secrets -n dojo-rbac \
  --as=system:serviceaccount:dojo-rbac:deployer
# -> no

# Impersonate a user and a group at once
kubectl get pods -n dojo-rbac --as=jane --as-group=dev-team

# Enumerate everything a subject can do in a namespace
kubectl auth can-i --list -n dojo-rbac \
  --as=system:serviceaccount:dojo-rbac:deployer
```

`auth can-i --list` is the fastest audit you have: it prints the full effective permission matrix for a subject in one shot. Run it against every ServiceAccount that matters before you ship.

> **`--as` is itself a privilege.** Impersonation is how a `cluster-admin` tests least privilege — but it's also a textbook escalation primitive. If a subject has `impersonate` on `users`/`groups`/`serviceaccounts`, they can *become* anyone, so a seemingly narrow grant plus `impersonate` equals cluster-admin. Treat `impersonate` as a crown-jewel verb.

A gotcha that wastes real debugging time: `kubectl auth can-i` returns **`yes` for everything when you forget `--as`**, because *you* are cluster-admin. The check is only meaningful when you're asking about another subject, so make `--as=...` a reflex. And `can-i` evaluates RBAC only — it can answer `yes` while an admission webhook (Kyverno, OPA/Gatekeeper, Pod Security) still rejects the actual request, so a `yes` from `can-i` is necessary but not sufficient proof the operation will succeed.

---

## Least privilege, and the over-grants that quietly happen

The failure mode is almost never "someone deliberately gave out cluster-admin." It's accretion. The usual suspects, in order of how often they show up in a real audit:

| Anti-pattern | Why it's dangerous | The fix |
|--------------|--------------------|---------|
| `verbs: ["*"]` | Grants `delete`, `deletecollection`, `escalate`, `bind` you never meant to | Enumerate the exact verbs |
| `resources: ["*"]` / `apiGroups: ["*"]` | Includes `secrets`, `rolebindings`, `*/exec` | Name the resources |
| Binding to the built-in `cluster-admin` ClusterRole | Total control, cluster-wide | Bind a scoped ClusterRole with a RoleBinding |
| `ClusterRoleBinding` where a `RoleBinding` would do | Grant leaks into every namespace | Use a namespaced RoleBinding |
| Token mounted into a pod that never calls the API | Ready-made credential for an attacker | `automountServiceAccountToken: false` |
| `get`/`list` on `secrets` granted broadly | base64 is not encryption (see Module 02) — this is plaintext exfiltration | Scope to one SA + `resourceNames` |

Two verbs deserve special fear because they are **privilege-escalation verbs** and the API server guards them specially:

- `escalate` on `roles`/`clusterroles` — lets you create a Role with *more* permissions than you currently hold (normally the API server blocks that).
- `bind` on `roles`/`clusterroles` — lets you create a binding to a role whose permissions exceed your own.

Grant either, or grant write access to `roles`/`rolebindings` themselves, and you've effectively granted the ability to become admin. A subject who can `create rolebindings` in a namespace can bind themselves to `cluster-admin` there. Audit for these first.

---

## Auditing RBAC

Reading YAML by eye doesn't scale past a handful of bindings. The questions you actually need to answer are "who can do X?" and "what can this subject do?" — both are reverse lookups RBAC doesn't index natively.

```bash
# Every binding and what it points at
kubectl get clusterrolebindings,rolebindings -A \
  -o custom-columns=KIND:.kind,NAME:.metadata.name,NS:.metadata.namespace,ROLE:.roleRef.name

# Who is bound to the all-powerful cluster-admin?  (the first thing to check)
kubectl get clusterrolebindings -o json | \
  grep -B4 '"name": "cluster-admin"'

# What can a specific ServiceAccount actually do?
kubectl auth can-i --list -n dojo-rbac \
  --as=system:serviceaccount:dojo-rbac:deployer

# Which subjects can read secrets cluster-wide? (the exfiltration question)
kubectl auth can-i get secrets --all-namespaces --as=system:serviceaccount:dojo-rbac:deployer
```

For anything bigger, reach for purpose-built tools: `kubectl-who-can` (`krew install who-can`) answers "who can `delete pods`?" directly, and `rakkess`/`kubectl access-matrix` prints the full access grid. In CI, lint manifests with a policy engine (Kyverno, OPA/Gatekeeper, or `conftest`) that fails the build on `verbs: ["*"]`, any bind to `cluster-admin`, or write access to `rbac.authorization.k8s.io`.

> **Audit-log reality.** When you investigate an incident, the API audit log identifies the actor as `system:serviceaccount:<ns>:<name>` or the OIDC username — which is only as useful as your RBAC is granular. If every CI job shares one over-powered ServiceAccount, the audit log can't tell you which pipeline did the damage. Least privilege isn't just prevention; it's attribution.

---

## Debugging RBAC & "Forbidden"

An RBAC denial is loud and precise — the API server tells you the exact user, verb, resource, and group it refused. Learn to read that one line and 90% of RBAC debugging is parsing, not guessing. A typical message:

```
Error from server (Forbidden): pods is forbidden:
  User "system:serviceaccount:dojo-rbac:deployer" cannot list resource "pods"
  in API group "" in the namespace "dojo-rbac"
```

Four facts are handed to you: the **subject** (`...:deployer`), the **verb** (`list`), the **resource + apiGroup** (`pods` in `""`), and the **namespace**. Your grant must match all four. The table maps the common failures:

| Symptom | Likely cause | Confirm / fix |
|---------|-------------|---------------|
| `Forbidden` for an SA that "has a RoleBinding" | `subjects[].namespace` omitted or wrong → binding matches nothing | `kubectl get rolebinding B -o jsonpath='{.subjects}'`; set namespace to the SA's home ns |
| `Forbidden` only for `logs`/`exec`, reads otherwise work | Rule grants `pods` but not the `pods/log` / `pods/exec` **subresource** | Add `resources: ["pods/log","pods/exec"]` |
| Grant "exists" but still denied, no typo visible | Resource in the **wrong apiGroup** (`deployments` under `""` instead of `apps`) | Check `.roleRef` → the Role's `rules[].apiGroups`; move resource to correct group |
| RoleBinding → ClusterRole works in one ns, not another | RoleBinding only grants in **its own** namespace; you need one per namespace | Create a RoleBinding in each target ns (or a ClusterRoleBinding if truly cluster-wide) |
| Pod's app gets 403 from the API, your `kubectl` works fine | App using the **wrong SA token** (default SA, or token not mounted) | Check `spec.serviceAccountName`; read the token's subject (below) |
| `auth can-i` says `yes` but the apply is rejected | An **admission webhook** (Kyverno/Gatekeeper/PSA), not RBAC, is denying it | `kubectl apply` and read the webhook name in the error |
| `roleRef` edit "doesn't take" | `roleRef` is **immutable** | `kubectl delete` the binding and recreate it |

The workflow, every time, starts with `auth can-i` against the *actual* subject — not yourself:

```bash
# 1. Reproduce the denial as the real subject (NOT as cluster-admin-you)
kubectl auth can-i list pods -n dojo-rbac \
  --as=system:serviceaccount:dojo-rbac:deployer
# -> no   (now you've confirmed it's RBAC, not the app)

# 2. Dump the subject's FULL effective permissions — find what's actually granted
kubectl auth can-i --list -n dojo-rbac \
  --as=system:serviceaccount:dojo-rbac:deployer

# 3. Find the bindings that touch this SA, and the roles they point at
kubectl -n dojo-rbac get rolebindings -o json \
  | grep -A6 '"subjects"' | grep -E 'name|namespace'
kubectl -n dojo-rbac get rolebinding deployer-can-manage-deploys \
  -o jsonpath='{.roleRef.kind}/{.roleRef.name}{"\n"}'

# 4. Read the role's actual rules — compare groups/resources/verbs to the error line
kubectl -n dojo-rbac get role deployment-manager \
  -o jsonpath='{range .rules[*]}groups={.apiGroups} res={.resources} verbs={.verbs}{"\n"}{end}'
```

When the suspect is a **pod using the wrong token**, inspect what identity it's actually carrying. The projected token is a JWT; decode its payload to see the SA it authenticates as (no `jq` needed — `base64 -d` on the middle segment):

```bash
# What SA is this pod really running as?
kubectl -n dojo-rbac get pod <pod> -o jsonpath='{.spec.serviceAccountName}{"\n"}'

# Pull the mounted token and decode its claims (the 'sub' is the SA identity)
TOKEN=$(kubectl -n dojo-rbac exec <pod> -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token)
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null; echo
# -> look for "sub":"system:serviceaccount:dojo-rbac:deployer"

# Or let the API server tell you who a token is — the authoritative answer
kubectl create token deployer -n dojo-rbac --duration=10m \
  | xargs -I{} kubectl auth whoami --token={}
```

For node-level and control-plane RBAC questions on the kind lab (cluster `dojo`), the audit log and apiserver flags live inside the control-plane container:

```bash
# Confirm which authorization modes are actually enabled on the apiserver
docker exec dojo-control-plane \
  grep -o 'authorization-mode=[^ ]*' /etc/kubernetes/manifests/kube-apiserver.yaml
```

> **War story.** A CI pipeline for the metering service started failing every deploy with `deployments.apps is forbidden`, but *only* for the new staging namespace — the identical binding in prod worked. The engineer on call spent an hour re-reading the ClusterRole, which was fine. The bug: they'd copied the `RoleBinding` into the staging namespace but left `subjects[].namespace: metering-prod` pointing at the prod SA, while the staging pod ran as the staging SA. The binding was valid, applied cleanly, and granted permissions to an identity that wasn't making the request — so the API server denied the real caller with a textbook `Forbidden`. `kubectl auth can-i --list --as=system:serviceaccount:metering-staging:ci` returned an almost-empty matrix and pointed straight at it in thirty seconds. The lesson that stuck: **when an SA is denied despite "having a binding," check the binding's `subjects[].namespace` before you ever re-read the Role** — a mismatched or missing subject namespace is a silent no-op, not an error.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. State the difference between a `Role` and a `ClusterRole`, and explain what a `RoleBinding` → `ClusterRole` combination grants versus a `ClusterRoleBinding` → the same ClusterRole.
2. Explain why `get pods` does not let you run `kubectl logs`, and name the subresource that does.
3. Describe where a pod's ServiceAccount token is mounted and why a *bound* projected token is safer than the legacy Secret token.
4. Use `kubectl auth can-i --list --as=system:serviceaccount:...` to dump a ServiceAccount's effective permissions.
5. Name the two privilege-escalation verbs (`escalate`, `bind`) and explain why `create rolebindings` is effectively a path to cluster-admin.
6. Read a `Forbidden` message and name the four facts it hands you (subject, verb, resource+group, namespace) that your grant must satisfy.
7. Explain why a RoleBinding to a ServiceAccount with a missing or wrong `subjects[].namespace` silently grants nothing.
8. Decode a mounted projected token to find the exact SA identity a misbehaving pod is authenticating as.
9. Explain why `kubectl auth can-i` can answer `yes` while the real request is still rejected by an admission webhook.

➡ Next up: **GitOps with ArgoCD** — we stop running `kubectl apply` by hand and make Git the source of truth, with a controller that continuously reconciles the cluster to match it.
