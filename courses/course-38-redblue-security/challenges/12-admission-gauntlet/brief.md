# Admission Gauntlet — Five Policies Block Five Attacks

Five attack patterns. Five policies. All five must pass.

This challenge deploys 5 "attack pods" — deliberately misconfigured Kubernetes specs that represent real attack techniques. Your job is to write OPA Gatekeeper and Kyverno policies that BLOCK all five from being created.

The verifier will attempt to create each attack pod and confirm each is rejected.

## The Five Attacks

| # | Pod spec | Attack technique | Policy engine |
|---|----------|-----------------|---------------|
| 1 | `privileged: true` | Container escape via privileged flag | OPA Gatekeeper |
| 2 | `hostPath: /` | Node filesystem access | OPA Gatekeeper |
| 3 | No `resources.limits` | Resource exhaustion / crypto mining | Kyverno |
| 4 | `image: nginx` (no tag) | Image drift / mutable builds | Kyverno |
| 5 | `serviceAccountName: dojo-sec-gauntlet-admin` | SA with excessive RBAC | Kyverno |

## Setup

Gatekeeper and Kyverno are installed. Namespace `dojo-sec-gauntlet` exists. No policies are applied yet.

## Mission

Write and apply:
1. OPA ConstraintTemplate + Constraint for attacks 1 and 2
2. Kyverno ClusterPolicy for attacks 3, 4, and 5

Then run verify.sh — it attempts each attack pod and checks rejection.

## Policy Requirements

**OPA — Block Privileged:**
```yaml
# ConstraintTemplate: BlockPrivileged
# Constraint applied to: dojo-sec-gauntlet namespace
# Reject: pods where any container has securityContext.privileged: true
```

**OPA — Block HostPath Root:**
```yaml
# ConstraintTemplate: BlockHostPathRoot  
# Constraint applied to: dojo-sec-gauntlet namespace
# Reject: pods with hostPath.path == "/"
```

**Kyverno — Require Resource Limits:**
```yaml
# ClusterPolicy, namespace: dojo-sec-gauntlet
# Reject: pods where any container lacks resources.limits.cpu or resources.limits.memory
```

**Kyverno — No Untagged Images:**
```yaml
# ClusterPolicy, namespace: dojo-sec-gauntlet
# Reject: pods where image doesn't have a tag (image == "name" with no colon)
# Note: "name:latest" should also be rejected
```

**Kyverno — Block Specific High-Priv SA:**
```yaml
# ClusterPolicy, namespace: dojo-sec-gauntlet
# Reject: pods with serviceAccountName == "dojo-sec-gauntlet-admin"
```

## Rules of Engagement

- Namespace: `dojo-sec-gauntlet`
- Apply OPA and Kyverno resources, then run: `bash verify.sh`
- The verifier creates test pods and expects 403/admission-denied responses
