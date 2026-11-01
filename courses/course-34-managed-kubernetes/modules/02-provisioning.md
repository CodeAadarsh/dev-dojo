# Provisioning Clusters

> **Module 02 · Course 34** — Spinning up a cluster is a one-time command. Keeping it reproducible, auditable, and survivable across a blue-green upgrade is an infrastructure design problem. This module covers the right tooling and the failure modes nobody writes in the quickstart.

You already know the cluster is a managed control plane sitting on node groups you own. This module is about how you create and configure those two layers in a way that doesn't turn into a `kubectl drain`-every-node fire drill six months later.

---

## The CLI tools

Each cloud has a purpose-built CLI for its Kubernetes service. All three generate declarative config files you can commit to git.

### eksctl (AWS EKS)

`eksctl` is the AWS-blessed open-source CLI for EKS. It wraps CloudFormation.

```bash
# Install
brew install eksctl   # macOS; Linux: curl released binary

# Create a minimal cluster (generates + applies CloudFormation)
eksctl create cluster \
  --name dev \
  --region us-east-1 \
  --version 1.29 \
  --nodegroup-name workers \
  --node-type t3.medium \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 5 \
  --managed

# OR use a config file (preferred for repeatability):
eksctl create cluster -f cluster.yaml
```

A versioned eksctl cluster config:

```yaml
# cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: dev
  region: us-east-1
  version: "1.29"

iam:
  withOIDC: true          # required for IRSA (Module 03)

managedNodeGroups:
  - name: on-demand
    instanceType: t3.medium
    minSize: 1
    maxSize: 5
    desiredCapacity: 2
    labels:
      role: worker
    taints:
      - key: workload
        value: general
        effect: NoSchedule

  - name: spot
    instanceTypes: [t3.large, t3a.large, m5.large]
    spot: true
    minSize: 0
    maxSize: 10
    desiredCapacity: 0
    labels:
      role: spot
    taints:
      - key: spot
        value: "true"
        effect: NoSchedule
```

`eksctl` creates IAM roles, VPC + subnets, security groups, and kubeconfig in one shot. The downside: it's opinionated and CloudFormation output is verbose. For greenfield you want it; for brownfield you often need the lower-level Terraform modules instead.

### gcloud container (GKE)

```bash
# Create a Standard cluster
gcloud container clusters create dev \
  --region us-central1 \
  --release-channel regular \
  --num-nodes 2 \
  --machine-type e2-standard-2 \
  --workload-pool $(gcloud config get project).svc.id.goog \
  --enable-ip-alias

# Get credentials (writes to ~/.kube/config)
gcloud container clusters get-credentials dev --region us-central1
```

GKE-specific flags worth knowing:
- `--release-channel` pins upgrade behaviour (Rapid/Regular/Stable).
- `--workload-pool` enables Workload Identity (Module 03).
- `--enable-ip-alias` (VPC-native mode) is mandatory for Private Clusters and recommended everywhere — it uses alias IPs so pod IPs are routable in your VPC without NAT.

GKE Autopilot replaces node pools with a per-pod billing model:

```bash
gcloud container clusters create-auto dev \
  --region us-central1
```

With Autopilot, you specify pod resource requests and GKE allocates nodes. You cannot SSH into nodes or modify the OS. Debugging is limited to pod logs and events.

### az aks (AKS)

```bash
# Create a cluster
az aks create \
  --resource-group my-rg \
  --name dev \
  --kubernetes-version 1.29 \
  --node-count 2 \
  --node-vm-size Standard_D2s_v3 \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --generate-ssh-keys

# Get credentials
az aks get-credentials --resource-group my-rg --name dev
```

AKS uses Azure Resource Manager (ARM) or Bicep as its IaC layer. The `--enable-oidc-issuer` + `--enable-workload-identity` flags are the AKS equivalents of EKS IRSA (Module 03).

---

## Node pools vs node groups

The terminology differs by provider but the concept is the same: a named set of homogeneous nodes with shared instance type, labels, taints, and autoscaling parameters.

| Concept | AWS EKS | GKE | AKS |
|---------|---------|-----|-----|
| Group name | Managed Node Group | Node Pool | Node Pool |
| Homogeneous OS | Yes | Yes | Yes |
| Mixed instance types | Yes (with launch template) | No per pool | No per pool |
| Spot/preemptible | Spot node group | Spot node pool | Spot node pool |
| Taints at pool level | Yes (`eksctl`) | Yes | Yes |

### Taints and labels — the right pattern

Labels drive scheduling affinity; taints enforce it. Use both together:

```yaml
# Spot node pool taint (at node group creation)
taints:
  - key: node.kubernetes.io/spot
    value: "true"
    effect: NoSchedule

# Pod toleration — only pods that can handle eviction go here
tolerations:
  - key: node.kubernetes.io/spot
    operator: Equal
    value: "true"
    effect: NoSchedule

# + nodeSelector / affinity to steer deliberately
nodeSelector:
  role: spot
```

A node with a `NoSchedule` taint rejects any pod that does not tolerate it. Without the taint, spot nodes silently accept any pod, and your stateful workloads get evicted when spot capacity is reclaimed. Put the taint on at node group creation, not after — adding it later requires draining every existing node.

### On-demand vs spot architecture

```
                requests.cpu > 500m or stateful?
                        ↓ yes
        ┌───────────────────────────────┐
        │ on-demand node group          │
        │ t3.large, minSize=2           │
        │ no taint                      │
        └───────────────────────────────┘

                requests.cpu ≤ 500m, stateless, tolerates disruption?
                        ↓ yes
        ┌───────────────────────────────┐
        │ spot node group               │
        │ t3.large/t3a.large/m5.large   │
        │ taint: spot=true:NoSchedule   │
        │ PodDisruptionBudget required  │
        └───────────────────────────────┘
```

Spot instances on AWS can be reclaimed with a 2-minute warning. Always pair spot node groups with:
1. `PodDisruptionBudget` on the workload
2. Multiple instance families (fall back if one type is unavailable)
3. `terminationGracePeriodSeconds` ≥ 30 in your Deployment

---

## Terraform and Crossplane for clusters

CLI tools are fine for day-1. For day-2 (audit, drift detection, multi-cluster) you want IaC.

### Terraform (terraform-aws-modules/eks)

The `terraform-aws-modules/eks` community module is the standard for EKS:

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "dev"
  cluster_version = "1.29"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  enable_cluster_creator_admin_permissions = true

  # EKS Managed Node Groups
  eks_managed_node_groups = {
    workers = {
      ami_type       = "AL2_x86_64"
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 5
      desired_size   = 2

      labels = { role = "worker" }
    }
  }
}
```

The module outputs `cluster_endpoint`, `cluster_certificate_authority_data`, and an OIDC provider ARN. Feed these into your IRSA module (Module 03).

### Crossplane

Crossplane (CNCF) lets you manage cloud resources from within Kubernetes using CRDs. You run Crossplane in a management cluster (often a cheap k3s or GKE free-tier) and it provisions EKS/GKE/AKS clusters as Kubernetes objects:

```yaml
apiVersion: eks.aws.upbound.io/v1beta1
kind: Cluster
metadata:
  name: dev
spec:
  forProvider:
    region: us-east-1
    version: "1.29"
    vpcConfig:
      - subnetIds: [subnet-aaa, subnet-bbb]
        endpointPublicAccess: true
```

Crossplane is compelling for platform teams already living in Kubernetes, but the blast radius of a misconfigured provider or broken CRD reconciliation is real. Most teams start with Terraform and graduate to Crossplane when they have the platform engineering bandwidth.

---

## Bootstrapping add-ons

After the cluster is up, you need a working cluster before workloads go on. The standard bootstrap order:

```
Cluster ready
    ↓
1. CNI plugin configured (often the default, but VPC CNI on EKS needs config)
    ↓
2. CoreDNS healthy (verify: kubectl -n kube-system get pods | grep coredns)
    ↓
3. Cluster Autoscaler or Karpenter (Module 05) — otherwise nodes don't scale
    ↓
4. Ingress controller (ALB controller / nginx) — external traffic
    ↓
5. cert-manager (TLS)
    ↓
6. metrics-server (HPA requires it: kubectl top nodes)
    ↓
7. Your workloads
```

Bootstrap add-ons with Helm rather than raw `kubectl apply` — you get versioned upgrades, values overrides, and drift detection with `helm diff`:

```bash
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --set controller.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::ACCOUNT:role/ebs-csi-driver-role
```

---

## Debugging: node group misconfig, IAM, add-on version mismatch

### Node group fails to launch — instances never join

Symptom: `kubectl get nodes` shows fewer nodes than desired; node group `desiredCapacity` is set but no new nodes appear.

Diagnose at the auto-scaling layer, not the Kubernetes layer:

```bash
# EKS: check the Auto Scaling Group events
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name <node-group-asg-name> \
  --max-items 10

# Most common reasons:
# - "InsufficientInstanceCapacity" → spot type unavailable; add fallback types
# - "Launch template version mismatch" → eksctl updated the LT but ASG pinned to old version
# - "Failed to start userdata" → IAM role missing ec2:DescribeInstances or ecr:GetAuthorizationToken

# GKE: node pool errors appear here
gcloud container operations list --filter="status=RUNNING"
gcloud container operations describe OPERATION_ID
```

### IAM for the node role — the most over-permissioned thing in EKS

Every EKS worker node has an IAM role attached to it. The minimum required policies:

```
AmazonEKSWorkerNodePolicy
AmazonEKS_CNI_Policy          (or attach to IRSA service account instead)
AmazonEC2ContainerRegistryReadOnly
```

Do NOT attach `AdministratorAccess` or `AmazonEC2FullAccess` to the node role — any pod running on the node can call the IMDS and get the node's credentials. This is a real attack vector (Module 03 goes deep). The blast radius of a compromised pod on an over-permissioned node is your entire AWS account.

```bash
# Check what policies are attached to the node role
aws iam list-attached-role-policies --role-name <node-iam-role-name>

# Find your node role name
aws eks describe-nodegroup \
  --cluster-name dev \
  --nodegroup-name workers \
  --query 'nodegroup.nodeRole' --output text
```

### Add-on version mismatch after cluster upgrade

When you upgrade a cluster (e.g., 1.27 → 1.28) on EKS, managed add-ons (CoreDNS, kube-proxy, VPC CNI) do not automatically upgrade to the version recommended for 1.28.

```bash
# Find the recommended add-on version for the new cluster version
aws eks describe-addon-versions \
  --kubernetes-version 1.28 \
  --addon-name coredns \
  --query 'addons[0].addonVersions[0].addonVersion' --output text

# Check what is currently deployed
aws eks describe-addon \
  --cluster-name dev \
  --addon-name coredns \
  --query 'addon.addonVersion' --output text

# Upgrade
aws eks update-addon \
  --cluster-name dev \
  --addon-name coredns \
  --addon-version v1.11.1-eksbuild.4   # use the output of describe-addon-versions
```

The symptom of a version mismatch is usually subtle: CoreDNS starts returning SERVFAIL for certain record types, or kube-proxy fails to sync iptables rules silently. Check `kubectl -n kube-system logs` for each add-on after a cluster upgrade as a matter of habit.

### Node group stuck "Degraded" after patch

If a managed node group reports `DEGRADED` after a node update, individual node launch failures are the usual cause:

```bash
aws eks describe-nodegroup \
  --cluster-name dev \
  --nodegroup-name workers \
  --query 'nodegroup.health'
```

The `health.issues` field tells you the exact error code. Common ones:
- `NodeCreationFailure` + `InsufficientFreeAddresses` → subnet IP exhaustion (Module 04)
- `AccessDenied` in the `issues` message → node role missing a permission
- `AmiIdNotFound` → custom AMI ID doesn't exist in the target region; happens when copying a cluster config across regions

---

## Checkpoint

You are ready for Module 03 when you can answer:

1. What does `eksctl create cluster -f cluster.yaml` create in addition to the EKS control plane? (Name at least three AWS resources.)
2. A new spot node joined the cluster but a pod with `nodeSelector: {role: spot}` is still `Pending`. Name the two most likely causes.
3. You added a `NoSchedule` taint to an existing node group (not at creation). What must you do to workloads already running on those nodes?
4. You upgraded EKS from 1.27 to 1.28. CoreDNS pods are `Running` but DNS resolution inside pods is failing intermittently. What is the first thing you check?
5. What minimum IAM policies must the EKS node role have, and why must it never have `AdministratorAccess`?
6. You're using `gcloud container clusters create-auto`. An engineer SSH-es into a node to debug a network issue. What happens?

➡ Next up: **Cloud IAM & Workload Identity** — how pods authenticate to S3, GCS, or Azure Blob without node-level credentials.
