# Solution — IRSA / Workload Identity — Scoped Pod Access

The flag is `KUBE{irsa_not_node_wide_creds}`.

## Why node-wide credentials are dangerous

The EC2 instance profile (or GKE node service account) is attached to the *node*, not the pod. Any process that can reach the metadata endpoint `169.254.169.254` — including a process inside a compromised container — inherits that role. A single `s3:GetObject` permission on the node becomes a credential for every pod running anywhere on that node.

IRSA solves this with a projected OIDC token that is pod-scoped. STS validates the token audience (`sts.amazonaws.com`) against the cluster's OIDC provider, then issues short-lived credentials for only the annotated role.

## EKS IRSA — complete manifests

### `serviceaccount.yaml`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ml-trainer
  namespace: prod
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/ml-trainer-s3-read
```

The annotation value is the IAM role ARN. The role's trust policy must allow the OIDC provider to call `sts:AssumeRoleWithWebIdentity` with a `sub` condition matching `system:serviceaccount:prod:ml-trainer`.

**Trust policy snippet (for reference):**

```json
{
  "Condition": {
    "StringEquals": {
      "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE:sub":
        "system:serviceaccount:prod:ml-trainer",
      "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE:aud":
        "sts.amazonaws.com"
    }
  }
}
```

### `deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ml-trainer
  namespace: prod
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ml-trainer
  template:
    metadata:
      labels:
        app: ml-trainer
    spec:
      serviceAccountName: ml-trainer
      containers:
        - name: trainer
          image: python:3.12-slim
          command: ["python3", "-c", "import time; time.sleep(3600)"]
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
```

The key field is `spec.template.spec.serviceAccountName: ml-trainer` — the exact name of the ServiceAccount. The Kubernetes token controller automatically mounts the projected OIDC token into the pod.

## GKE Workload Identity — equivalent

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ml-trainer
  namespace: prod
  annotations:
    iam.gke.io/gcp-service-account: ml-trainer@my-gcp-project.iam.gserviceaccount.com
```

The GCP service account must have the binding:
```
gcloud iam service-accounts add-iam-policy-binding \
  ml-trainer@my-gcp-project.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:my-gcp-project.svc.id.goog[prod/ml-trainer]"
```

## How to verify it's working (on a real cluster)

```bash
kubectl exec -it <pod-name> -n prod -- \
  python3 -c "import boto3; print(boto3.client('sts').get_caller_identity())"
# Should print the scoped role ARN, not the node role

# On EKS: confirm the projected token is mounted
kubectl exec -it <pod-name> -n prod -- \
  ls /var/run/secrets/eks.amazonaws.com/serviceaccount/
```

## Hardening preview

1. **Audit the trust policy `sub` condition.** Forgetting the `sub` condition allows any pod in any namespace to assume the role — a common misconfiguration.
2. **Set `automountServiceAccountToken: false`** on the SA for pods that do NOT need cloud credentials. Token projection has a cost (refreshed every 24h by default).
3. **Use `externalSecrets` or AWS Secrets Manager** for static secrets instead of relying on IAM credential retrieval in-flight.
4. **`eks.amazonaws.com/token-expiration`** annotation on the SA overrides the default 24h token TTL — set it to 3600 (1h) for high-value roles.
