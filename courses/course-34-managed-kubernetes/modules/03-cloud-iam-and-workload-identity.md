# Cloud IAM & Workload Identity

> **Module 03 · Course 34** — The pod needs to read from S3. You could put an AWS key in a Secret. You should not. The right answer — IRSA on EKS, Workload Identity on GKE, federated identity on AKS — is what separates production-grade from "it works in dev." This module draws the full trust chain.

If you have ever seen an `AccessDenied` from a pod and reached for `AWS_ACCESS_KEY_ID` in a Deployment, this module is exactly where to start. That pattern is a ticking incident: keys rotate poorly, get committed to git, and have no blast-radius boundary when a container escapes.

---

## The problem: pod → cloud auth

Kubernetes does not natively know about AWS IAM, GCP IAM, or Azure RBAC. Out of the box, any code running in a pod authenticates to cloud APIs the same way you do locally: credentials baked into the environment.

The naive approaches and their failure modes:

| Approach | Why it fails |
|----------|-------------|
| `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` in env vars / Secret | Static, must rotate manually, leaked on `kubectl describe`, committed to git, blast radius = everyone who touches the Secret |
| Node IAM role with broad permissions | Every pod on every node gets the same credentials via IMDS; a container escape → full node role access |
| Shared service account key (GCP) / client secret (Azure) | Same as option 1: static credential, broad scope, rotation is manual |

The solution is to tie pod identity to a Kubernetes ServiceAccount via OIDC federation, so the cloud's IAM system can verify *this specific ServiceAccount in this specific namespace* is who it claims to be — with no long-lived secret anywhere.

---

## OIDC: the trust anchor

All three workload identity systems use the same foundation: your Kubernetes cluster acts as an OpenID Connect (OIDC) provider. When a pod uses a ServiceAccount, the kubelet mounts a signed JWT (a projected ServiceAccount token) into the pod. The cloud IAM system verifies that JWT against the cluster's OIDC issuer endpoint, then hands back short-lived cloud credentials.

```
                                      ┌─ Cloud IAM (AWS / GCP / Azure) ─┐
                                      │                                  │
   Pod starts                         │  2. Verify JWT signature against  │
       ↓                              │     the cluster's OIDC issuer URL │
   Kubelet mounts projected token  ──►│  3. Check: does this SA/namespace │
   (JWKS-signed JWT) in pod           │     match an IAM role trust policy?│
       ↓                              │  4. Return short-lived creds      │
   Pod calls cloud IAM                │     (AWS STS token, GCP access    │
   (via SDK or metadata proxy)     ◄──│      token, Azure token)          │
       ↓                              └──────────────────────────────────┘
   Calls cloud API (S3, GCS, etc.)
   with the short-lived creds
   (expire in 1h; auto-refreshed)
```

The OIDC issuer URL is the cluster's public discovery endpoint. AWS, GCP, and Azure each host this differently:
- **EKS**: `https://oidc.eks.<region>.amazonaws.com/id/<cluster-hash>` (created by `eksctl` when `withOIDC: true`)
- **GKE**: `https://container.googleapis.com/v1/projects/<project>/locations/<region>/clusters/<cluster>`
- **AKS**: `https://<oidc-issuer-host>/<tenant-id>/` (enabled with `--enable-oidc-issuer`)

---

## IRSA — IAM Roles for Service Accounts (EKS)

IRSA lets an EKS ServiceAccount assume an IAM role. The trust policy on the IAM role limits which exact ServiceAccount in which exact namespace can assume it.

### Step 1: create the IAM role with an OIDC trust policy

```bash
# Get the OIDC issuer URL for your cluster
OIDC=$(aws eks describe-cluster --name dev \
  --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# Create the trust policy
cat > trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC}:sub": "system:serviceaccount:my-app:s3-reader",
        "${OIDC}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

# Create the role and attach the policy you need
aws iam create-role --role-name s3-reader-role --assume-role-policy-document file://trust.json
aws iam attach-role-policy --role-name s3-reader-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
```

### Step 2: annotate the ServiceAccount

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: s3-reader
  namespace: my-app
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/s3-reader-role"
```

### Step 3: reference it in your Pod/Deployment

```yaml
spec:
  serviceAccountName: s3-reader
  # Nothing else needed — the AWS SDK auto-discovers the
  # projected token at /var/run/secrets/eks.amazonaws.com/serviceaccount/token
  containers:
    - name: app
      image: my-app:1.2.3
      # AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE are auto-injected
      # by the pod identity mutating webhook when the SA annotation is present
```

The EKS Pod Identity Agent (newer alternative to the original IRSA webhook) simplifies this further: you create a `PodIdentityAssociation` resource and the agent handles token exchange transparently.

### eksctl shortcut

```bash
eksctl create iamserviceaccount \
  --name s3-reader \
  --namespace my-app \
  --cluster dev \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
  --approve
```

---

## GKE Workload Identity

GKE's equivalent binds a Kubernetes ServiceAccount to a GCP Service Account via IAM.

### Step 1: create a GCP Service Account

```bash
PROJECT=$(gcloud config get-value project)

gcloud iam service-accounts create gcs-reader \
  --display-name "GCS reader for my-app"

# Grant it the GCS role you need
gcloud projects add-iam-policy-binding $PROJECT \
  --member "serviceAccount:gcs-reader@${PROJECT}.iam.gserviceaccount.com" \
  --role "roles/storage.objectViewer"
```

### Step 2: bind the K8s ServiceAccount to the GCP SA

```bash
gcloud iam service-accounts add-iam-policy-binding \
  gcs-reader@${PROJECT}.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:${PROJECT}.svc.id.goog[my-app/gcs-reader]"
```

The binding format is `serviceAccount:<project>.svc.id.goog[<namespace>/<k8s-sa-name>]`.

### Step 3: annotate the K8s ServiceAccount

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gcs-reader
  namespace: my-app
  annotations:
    iam.gke.io/gcp-service-account: "gcs-reader@my-project.iam.gserviceaccount.com"
```

With GKE Metadata Server enabled (default on Autopilot; set `--workload-pool` on Standard), the GKE metadata server intercepts IMDS calls from pods using an annotated SA and returns GCP access tokens scoped to the bound GCP SA.

---

## AKS Workload Identity

AKS Workload Identity uses Azure Active Directory federated credentials.

```bash
OIDC_ISSUER=$(az aks show --name dev --resource-group my-rg \
  --query "oidcIssuerProfile.issuerUrl" -o tsv)

# Create a managed identity
az identity create --name storage-reader --resource-group my-rg
CLIENT_ID=$(az identity show --name storage-reader --resource-group my-rg \
  --query clientId -o tsv)

# Assign Azure RBAC role (Storage Blob Data Reader)
az role assignment create \
  --role "Storage Blob Data Reader" \
  --assignee $CLIENT_ID \
  --scope /subscriptions/SUB/resourceGroups/my-rg/providers/Microsoft.Storage/storageAccounts/mystorageaccount

# Federate the managed identity to the K8s ServiceAccount
az identity federated-credential create \
  --name my-app-federated \
  --identity-name storage-reader \
  --resource-group my-rg \
  --issuer $OIDC_ISSUER \
  --subject "system:serviceaccount:my-app:storage-reader"
```

```yaml
# ServiceAccount annotation
apiVersion: v1
kind: ServiceAccount
metadata:
  name: storage-reader
  namespace: my-app
  annotations:
    azure.workload.identity/client-id: "CLIENT_ID_HERE"
```

Pods also need the label `azure.workload.identity/use: "true"` on the Pod spec (or Deployment template) for the mutating webhook to inject the token.

---

## Scoping: no node-wide credentials

The pattern above is the scoping principle: credentials are scoped to a specific ServiceAccount, not a node.

```
WRONG:
  Node IAM role → AmazonS3FullAccess
  → pod on node A, pod on node B, pod on node C all have the same creds
  → compromised pod X = full S3 access from any pod on the node

RIGHT (IRSA):
  IAM role s3-reader-role → AmazonS3ReadOnlyAccess
  Trust policy: ONLY system:serviceaccount:my-app:s3-reader can assume it
  → compromised pod X using default SA → no S3 access
  → compromised pod X in my-app using wrong SA → no S3 access
  → only the exact pod with the exact SA can access the exact bucket
```

The principle is least-privilege at the identity boundary, not at the node boundary. This is why IRSA/WI is a security requirement, not just a convenience.

---

## The IMDS risk

The Instance Metadata Service (IMDS) is a per-node HTTP endpoint available at `http://169.254.169.254`. It is the mechanism by which the node's IAM role credentials are vended. Any code running on the node — including any pod — can reach it:

```bash
# From inside a pod (no auth required on IMDSv1):
curl http://169.254.169.254/latest/meta-data/iam/security-credentials/
# Returns: the node role name
curl http://169.254.169.254/latest/meta-data/iam/security-credentials/my-node-role
# Returns: AccessKeyId, SecretAccessKey, Token — valid for ~6 hours
```

This is the attack path when a pod is compromised on a node with an over-permissioned IAM role. It requires no Kubernetes privilege — just the ability to make outbound HTTP from a pod, which is the default.

**IMDSv2** breaks this for most attacks by requiring a PUT request to get a session token first, and allows you to set a `http-put-response-hop-limit=1` at the instance level, which prevents pods (which are behind one network hop) from reaching the IMDS:

```bash
# EKS: enforce IMDSv2 on all new nodes via the launch template
aws ec2 modify-instance-metadata-options \
  --instance-id i-xxx \
  --http-tokens required \
  --http-put-response-hop-limit 1
# In eksctl config:
# managedNodeGroups[].instanceMetadataOptions.httpPutResponseHopLimit: 1
# managedNodeGroups[].instanceMetadataOptions.httpTokens: required
```

With `hop-limit=1`, the request to IMDS from a pod (which goes through a veth pair and the node's Linux bridge — 2 hops) is dropped. A process on the node itself (1 hop) still works, so kubelet keeps functioning.

**If you use IRSA + IMDSv2 with hop-limit=1, the node role credentials are completely unavailable to pods.** This is the recommended production baseline.

---

## Debugging: AccessDenied from a pod, over-broad node role, IMDSv2

### `AccessDenied` when calling an AWS API from a pod

Work through the chain from the pod out:

```bash
# 1. Does the pod have the IRSA annotation visible?
kubectl get pod <pod-name> -o jsonpath='{.spec.serviceAccountName}'
kubectl get serviceaccount <sa-name> -n <namespace> \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
# If empty → the SA is not annotated; IRSA is not configured

# 2. Is the projected token present?
kubectl exec -it <pod> -- ls /var/run/secrets/eks.amazonaws.com/serviceaccount/
# Should list: token
# If no directory → the pod identity webhook did not mutate this pod
# (check: kubectl get mutatingwebhookconfigurations | grep pod-identity)

# 3. Check the IAM role trust policy
aws iam get-role --role-name s3-reader-role \
  --query 'Role.AssumeRolePolicyDocument'
# Look for: does the Condition StringEquals match your actual namespace + SA name?
# Common mistake: "system:serviceaccount:wrong-namespace:s3-reader"

# 4. Check the permission policy attached to the role
aws iam list-attached-role-policies --role-name s3-reader-role

# 5. Does the OIDC provider exist?
aws iam list-open-id-connect-providers
# If empty → eksctl create iamserviceaccount skipped OIDC setup
# Fix: eksctl utils associate-iam-oidc-provider --cluster dev --approve
```

### Over-broad node role — detecting and fixing

```bash
# List all policies on the node role (see Module 02 for getting the role name)
aws iam list-attached-role-policies --role-name <node-role-name>
aws iam list-role-policies --role-name <node-role-name>   # inline policies

# If you see PowerUserAccess, AdministratorAccess, or S3FullAccess → over-broad
# Detach and replace with minimum:
aws iam detach-role-policy --role-name <node-role-name> \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
# Attach minimum required:
aws iam attach-role-policy --role-name <node-role-name> \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam attach-role-policy --role-name <node-role-name> \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
```

### IMDSv2 troubleshooting

If pods that previously worked start failing after you enforce IMDSv2 with `hop-limit=1`, an older AWS SDK version might not support IMDSv2 (SDKs before mid-2019 don't). The fix is to update the SDK, not to relax the hop limit.

```bash
# From a pod: test whether IMDSv2 with hop-limit=1 blocks the request
kubectl run imds-test --rm -it --image=curlimages/curl:8.5.0 -- \
  sh -c 'TOKEN=$(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" http://169.254.169.254/latest/api/token) && echo TOKEN=$TOKEN && curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/'
# With hop-limit=1: the PUT returns nothing, TOKEN is empty, second curl fails
# This is the desired state — pods cannot reach IMDS
```

For GKE Workload Identity debugging:

```bash
# From a pod using an annotated SA — is the GKE metadata server responding?
kubectl exec -it <pod> -- curl -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token
# Should return an access token scoped to the bound GCP SA
# If 403 → binding between K8s SA and GCP SA is missing or wrong namespace/name
```

---

## Checkpoint

You are ready for Module 04 when you can:

1. Draw the OIDC trust chain for IRSA: from the JWT in the pod, through STS, to short-lived credentials. Name every component.
2. Write the IRSA trust policy condition that restricts access to *only* `system:serviceaccount:payments:stripe-reader`. Why does the namespace matter?
3. A pod in namespace `billing` using ServiceAccount `sa-s3` gets `AccessDenied`. Your trust policy says `system:serviceaccount:billing:sa-s3`. List the three other things to check before touching IAM.
4. Explain why `hop-limit=1` on IMDSv2 protects workloads even without IRSA, and why IRSA is still better.
5. A junior engineer says "let's give the node role `AdministratorAccess` to stop these permission issues." Write the one-paragraph response explaining the blast radius, and name the actual minimum policies.
6. Compare GKE Workload Identity and IRSA: how are the binding steps different, and what is the GKE equivalent of the OIDC issuer URL?

➡ Next up: **Cloud Networking** — VPC CNI IP exhaustion, LoadBalancer annotations, private clusters, and the cross-AZ tax.
