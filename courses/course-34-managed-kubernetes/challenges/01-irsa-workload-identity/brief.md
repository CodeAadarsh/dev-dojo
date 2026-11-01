# IRSA / Workload Identity — Scoped Pod Access

A security audit flags your team's ML training pipeline: every pod on the EKS cluster carries the EC2 instance profile — a single IAM role that has `s3:*` on every bucket in the account. The auditor's note reads:

> *"Node-wide credentials violate least privilege. One compromised pod can exfiltrate every S3 bucket. Use IRSA to scope the training job to a single S3 bucket."*

You need to author the Kubernetes manifests that implement this fix.

## Context

`setup.sh` creates a work directory with two stubs:

```
~/.kube-dojo-work/01-irsa-workload-identity/
├── serviceaccount.yaml    # stub — complete the IRSA/WI annotation
└── deployment.yaml        # stub — bind the SA and confirm no fallback
```

The files are intentionally incomplete. `verify.sh` parses them with Python + PyYAML and checks the required structure — no cloud account needed.

## Prerequisites

```bash
pip3 install pyyaml    # or: pip install pyyaml
```

## Background: Why IRSA, Not the Instance Profile

When a pod runs without an explicit ServiceAccount, it uses `default` — which, in most managed clusters, inherits the node's instance profile or node service account. On AWS, that means the pod can call the EC2 metadata endpoint (`169.254.169.254`) and get credentials for the *node's* IAM role.

IRSA (IAM Roles for Service Accounts) breaks this coupling:

```
Without IRSA                          With IRSA
────────────────────────────────────  ──────────────────────────────────────
Pod → 169.254.169.254 → node role     Pod → projected OIDC token
      (entire node's permissions)           ↓
                                      STS:AssumeRoleWithWebIdentity
                                           ↓
                                      scoped IAM role (one bucket, R/W only)
```

The projected token is mounted at `/var/run/secrets/eks.amazonaws.com/serviceaccount/token` (EKS) or `/var/run/secrets/kubernetes.io/serviceaccount/token` (GKE Workload Identity). The AWS SDK / GCP client library detect the token automatically — application code changes are zero.

GKE Workload Identity works the same way with a different annotation key. This challenge accepts both.

## Mission

### Step 1 — Complete `serviceaccount.yaml`

A valid ServiceAccount for IRSA must:

1. Have a **non-`default`** name.
2. Carry one of these annotations (pick the provider your deployment targets):

| Provider | Annotation key | Value format |
|----------|---------------|--------------|
| AWS EKS IRSA | `eks.amazonaws.com/role-arn` | `arn:aws:iam::<account-id>:role/<role-name>` |
| GKE Workload Identity | `iam.gke.io/gcp-service-account` | `<sa-name>@<project>.iam.gserviceaccount.com` |

Use a realistic but placeholder ARN/email — the verifier checks **format and presence**, not that the role actually exists.

### Step 2 — Complete `deployment.yaml`

The Deployment must:

1. Set `spec.template.spec.serviceAccountName` to **the exact name** of your ServiceAccount.
2. Must **not** use `serviceAccountName: default`.

The verifier cross-references both files — they must agree on the ServiceAccount name.

## What the verifier checks

```
✓ serviceaccount.yaml — kind is ServiceAccount
✓ ServiceAccount name is not 'default'
✓ IRSA or WI annotation is present and correctly formatted
✓ deployment.yaml — kind is Deployment
✓ spec.template.spec.serviceAccountName is set
✓ serviceAccountName matches the ServiceAccount name
✓ serviceAccountName is not 'default'
```

## Verify

```bash
bash courses/course-34-managed-kubernetes/challenges/01-irsa-workload-identity/verify.sh
```

All checks pass → flag printed.
