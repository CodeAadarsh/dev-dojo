# Red Team Lab Boss — Full Kill Chain, Full Hardening

This is the final challenge. No hints, no handholding.

A deliberately misconfigured cluster is running in namespace `dojo-sec-boss`. You'll attack it through the full kill chain, then harden it completely. Both attack and hardening must succeed.

## The Setup

A vulnerable application is deployed:
- Pod `exposed-app` runs with the default SA and automounted token
- The default SA in `dojo-sec-boss` has a ClusterRoleBinding granting `cluster-admin`
- Namespace `dojo-sec-boss-vault` contains secret `crown-jewels`
- ClusterRoleBinding `dangerous-crb` exists and must be removed

## Attack Phase

You'll prove you completed the attack by creating a ConfigMap `attack-progress` in `dojo-sec-boss` with the following data:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: attack-progress
  namespace: dojo-sec-boss
data:
  step1: "read-sa-token"       # Read the SA token from exposed-app
  step2: "found-cluster-admin" # Discovered the token is cluster-admin
  step3: "read-crown-jewels"   # Read the crown-jewels secret
```

## Hardening Phase

After proving the attack, harden the cluster:

1. Delete `dangerous-crb` ClusterRoleBinding
2. Set `automountServiceAccountToken: false` on the default SA in `dojo-sec-boss`
3. Apply a default-deny NetworkPolicy to `dojo-sec-boss`
4. Delete and recreate `crown-jewels` secret in `dojo-sec-boss-vault` (rotation)

## Rules of Engagement

- Namespace: `dojo-sec-boss` and `dojo-sec-boss-vault`
- Run verify.sh when both attack and hardening are complete
- The flag is only revealed when ALL checks pass

## This Is It

You've studied the kill chain. You've practiced the defenses. This challenge puts it all together. Good luck.
