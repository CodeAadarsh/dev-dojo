# OPA Policy Escape

Your team deployed OPA Gatekeeper to block privileged containers. Policy is in place. CI is green. Everyone feels safe.

But a new privileged container just appeared in production. No one knows how it got past the policy.

This challenge asks you to find the gap in the OPA policy, understand why it's exploitable, and fix it. The flag is in a secret that's locked behind a correct policy — when your fix is in place and the policy properly blocks the attack, the verifier unlocks it.

## What's Deployed

- OPA Gatekeeper is installed in the cluster
- A `ConstraintTemplate` named `BlockPrivilegedContainer` exists
- A `Constraint` named `block-privileged-containers` applies it
- Namespace: `dojo-sec-opa`

## The Bug

The constraint is misconfigured. It was written to block Deployments but forgot about bare Pods. An attacker who creates a Pod directly (not via a Deployment) bypasses the policy entirely.

## Mission

1. Read the existing Constraint and understand the gap
2. Try creating a privileged bare Pod in `dojo-sec-opa` — it should fail but it DOESN'T
3. Fix the Constraint to also cover bare `Pod` resources
4. Run the verifier — it tries to create a privileged Pod and confirms it's rejected

## Why This Matters

OPA Gatekeeper policies are only as good as their `spec.match.kinds` section. A constraint that only matches `Deployment` doesn't protect you from:
- Bare Pods
- DaemonSets
- StatefulSets
- Jobs and CronJobs

Always test your policies with every resource type an attacker might use.

## Rules of Engagement

- Namespace: `dojo-sec-opa`
- Existing constraint: `kubectl get constraint block-privileged-containers -o yaml`
- Existing template: `kubectl get constrainttemplate blockprivilegedcontainer -o yaml`
- Fix the constraint by editing it: `kubectl edit constraint block-privileged-containers`
- Run the verifier to confirm the fix works
