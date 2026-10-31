# base64 Is Not Encryption

A developer on the billing team pushed back on a security review with: *"The DB password is fine, it's in a Kubernetes Secret — it's encrypted."*

It is **not** encrypted. By default, a Secret is merely **base64-encoded** at rest in etcd, and anyone with `get secret` permission (or access to the pod, or to etcd) can read it in plaintext. Your task is to drive that lesson home.

## Mission

The setup script deployed a `billing` workload in namespace `dojo-leaky`. Somewhere in that namespace is a Secret containing a flag in the form `KUBE{...}`.

**Extract the flag.** There are at least three legitimate ways to get it, and you should try to find more than one — each represents a real exfiltration path an attacker would use:

1. Read the Secret object directly and decode the value.
2. Read it from the running container's environment (the Deployment mounts the Secret as env vars).
3. Describe the pod / inspect how the secret is wired in.

Submit the flag you recover.

## Why this matters

If base64 were encryption, step 1 below would return gibberish. It returns the plaintext flag. That single fact is why real clusters need **encryption at rest** (EncryptionConfiguration on the API server), **RBAC that doesn't hand out `get secret` freely**, and ideally an external secrets manager. You'll harden exactly this in a later module.
