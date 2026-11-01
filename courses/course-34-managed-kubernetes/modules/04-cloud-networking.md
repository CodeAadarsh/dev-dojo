# Cloud Networking

> **Module 04 · Course 34** — Kubernetes networking in a cloud cluster is not the flat `/24` you get from a kind cluster. Pod IPs come from your VPC. LoadBalancers are real cloud resources. Cross-AZ traffic has a line item on the bill. Understanding the cloud CNI is what separates "I applied a YAML and it worked" from "I designed the subnet CIDR and it scaled."

Every networking problem in a managed cluster has two layers: the Kubernetes layer you can inspect with `kubectl`, and the cloud layer beneath it that kubectl cannot see. This module gives you both.

---

## The cloud CNI

A CNI (Container Network Interface) plugin is responsible for assigning IP addresses to pods and wiring up pod-to-pod connectivity. In a cloud cluster, the CNI plugin is also responsible for integrating with the underlying VPC networking.

### AWS VPC CNI (aws-node)

EKS uses the **AWS VPC CNI** (`aws-node` DaemonSet in `kube-system`). It assigns *actual VPC IP addresses* to pods — pods are first-class citizens in the VPC, routable without NAT.

```
┌─── VPC: 10.0.0.0/16 ─────────────────────────────────────────────────────────────┐
│                                                                                    │
│  ┌── Subnet 10.0.1.0/24 (us-east-1a) ──┐    ┌── Subnet 10.0.2.0/24 (us-east-1b) ┐│
│  │                                      │    │                                    ││
│  │  Node (10.0.1.5)                     │    │  Node (10.0.2.7)                   ││
│  │  ┌────┐  ┌────┐  ┌────┐             │    │  ┌────┐  ┌────┐                    ││
│  │  │pod │  │pod │  │pod │             │    │  │pod │  │pod │                    ││
│  │  │.10 │  │.11 │  │.12 │             │    │  │.20 │  │.21 │                    ││
│  │  └────┘  └────┘  └────┘             │    │  └────┘  └────┘                    ││
│  │  ▲ each pod IP is a VPC secondary IP│    │  ▲ directly routable in VPC        ││
│  └──────────────────────────────────────┘    └────────────────────────────────────┘│
│                                                                                    │
│  Database (10.0.3.50) ← pod at 10.0.1.10 can call it directly (no NAT)           │
└────────────────────────────────────────────────────────────────────────────────────┘
```

Each EC2 instance has a maximum number of network interfaces (ENIs) and a maximum number of IP addresses per ENI, determined by instance type. The VPC CNI pre-warms secondary IPs on each ENI so pods start fast. The IP capacity of a node is:

```
max_pods_per_node = (ENIs × IPs_per_ENI) - 1
```

For a `t3.medium`: 3 ENIs × 6 IPs - 1 = **17 pods maximum**. This is a hard cap imposed by the AWS networking layer, not Kubernetes.

```bash
# Check your node's max pod capacity
kubectl describe node <node-name> | grep "allocatable" -A 10
# Look for: pods: 17 (or whatever your instance type allows)

# See the VPC CNI config
kubectl -n kube-system describe daemonset aws-node | grep -A5 WARM_ENI_TARGET
```

**Prefix delegation mode** removes this cap on larger instances by allocating a `/28` (16 IPs) per ENI slot instead of single IPs. Enable it to scale pods past the per-instance ceiling:

```bash
kubectl set env daemonset aws-node -n kube-system \
  ENABLE_PREFIX_DELEGATION=true \
  WARM_PREFIX_TARGET=1
```

After enabling prefix delegation, drain and recycle nodes for it to take effect — the change doesn't retroactively expand running nodes.

### GKE CNI (dataplane v2 / Cilium)

GKE uses its own CNI called **Dataplane V2** (based on Cilium/eBPF) in standard clusters since 1.21. It also uses alias IPs (VPC-native mode), giving pods routable VPC IPs like EKS does. GKE Dataplane V2 enforces NetworkPolicy natively via eBPF maps — not iptables.

```bash
# Verify dataplane v2 is active
gcloud container clusters describe dev --region us-central1 \
  --format "value(networkConfig.datapathProvider)"
# Returns: ADVANCED_DATAPATH (= Dataplane V2) or LEGACY_DATAPATH
```

GKE allocates a `/24` pod CIDR per node by default. You configure the maximum number of pods per node at cluster creation time (`--max-pods-per-node`); GKE sizes the per-node pod CIDR accordingly.

### Azure CNI (AKS)

AKS supports two CNI modes:

1. **Kubenet** — nodes get VPC IPs; pods get an overlay CIDR (not routable in the VPC without user-defined routes). Simpler subnet requirements but you need UDRs for inter-node pod traffic.
2. **Azure CNI** — pods get VPC IPs (like EKS VPC CNI). Each pod consumes a VNet IP. Better performance; requires larger subnets.
3. **Azure CNI with dynamic IP allocation** — newer; assigns pod IPs from a separate subnet, reducing waste on the node subnet.

```bash
# Check which CNI mode is in use
az aks show --name dev --resource-group my-rg \
  --query "networkProfile.networkPlugin"
# Returns: kubenet or azure
```

---

## Service type LoadBalancer and cloud annotations

When you create a `Service` with `type: LoadBalancer`, the cloud-controller-manager provisions a real cloud load balancer and assigns an external IP. The default is a classic (L4) load balancer. Annotations control the type and behaviour.

### EKS — Classic ELB vs NLB

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  annotations:
    # Use a Network Load Balancer (L4, lower latency, static IPs)
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    # Make it internal (no internet exposure)
    service.beta.kubernetes.io/aws-load-balancer-internal: "true"
    # Restrict source CIDRs at the LB level
    service.beta.kubernetes.io/aws-load-balancer-source-ranges: "10.0.0.0/8,172.16.0.0/12"
    # Cross-zone load balancing (avoids cross-AZ hops for LB → node)
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
spec:
  type: LoadBalancer
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 8080
```

The modern approach is the **AWS Load Balancer Controller** (an add-on), which supports NLBs and Application Load Balancers natively via annotations on Service and via `Ingress` resources (ALB Ingress):

```yaml
# ALB Ingress via AWS Load Balancer Controller
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:123:certificate/abc
spec:
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

### GKE — GCLB (Google Cloud Load Balancer)

GKE's cloud-controller-manager creates a Google Cloud Load Balancer automatically. The `BackendConfig` CRD lets you configure health checks, CDN, and security policies:

```yaml
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: my-app-backend
spec:
  healthCheck:
    checkIntervalSec: 10
    timeoutSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 3
    type: HTTP
    requestPath: /healthz
  cdn:
    enabled: false
  connectionDraining:
    drainingTimeoutSec: 60
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  annotations:
    cloud.google.com/backend-config: '{"default": "my-app-backend"}'
    cloud.google.com/neg: '{"ingress": true}'   # Network Endpoint Group for direct pod routing
spec:
  type: ClusterIP   # NEG-based ingress doesn't need LoadBalancer type
```

GKE Container-native load balancing (NEGs) routes traffic directly to pod IPs, bypassing `kube-proxy` iptables rules. It is the recommended approach for GKE.

### AKS — Azure Load Balancer

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "internal-lb-subnet"
    service.beta.kubernetes.io/azure-pip-name: "my-static-ip"
spec:
  type: LoadBalancer
```

---

## Ingress and Gateway controllers

A `Service type: LoadBalancer` gives you one LB per Service — expensive and operationally noisy at scale. An Ingress controller fronts many Services with a single LB and does L7 routing.

```
Internet → LB (1) → Ingress Controller (nginx / ALB controller / Traefik)
                          ↓
               /api/*  → svc: api-service
               /web/*  → svc: frontend-service
               /admin/ → svc: admin-service (internal only)
```

**nginx Ingress** is cloud-agnostic and uses a single `LoadBalancer` Service. **ALB Ingress Controller** (EKS), **GKE Ingress** (GCLB), and **AKS Application Gateway Ingress Controller** are cloud-native and use their respective L7 load balancers.

The **Gateway API** (stable in K8s 1.28) replaces `Ingress` with a richer resource model (`Gateway`, `HTTPRoute`, `GRPCRoute`). All three clouds are migrating to it. For new clusters, prefer Gateway API over `Ingress` if your controller supports it.

---

## Private clusters

A private cluster has no public IPs on the nodes. The API server may also be private (no public endpoint) or have a public endpoint locked down to specific CIDR ranges.

```
Public internet
       │
       ▼ (optional: public endpoint with CIDR allowlist)
API server endpoint (VPC)
       │
   VPC peering / Transit Gateway / VPN
       │
       ▼
Worker nodes (no public IP, private subnets only)
       │
   NAT Gateway → pulls container images from ECR / Docker Hub
```

Private cluster tradeoffs:

| | Public cluster | Private cluster |
|---|---|---|
| Node public IP | Yes | No |
| API server publicly reachable | Yes (with auth) | No (VPN/bastion required) |
| Egress for image pulls | Direct internet | NAT Gateway required |
| Security posture | Lower | Higher |
| Setup complexity | Low | High (NAT GW, peering, VPN) |

On GKE, `--enable-private-nodes` removes public IPs from nodes. The control plane communicates to nodes via a peered VPC. On EKS, `--endpoint-private-access=true --endpoint-public-access=false` makes the API server endpoint only reachable from within the VPC.

```bash
# EKS: check endpoint access mode
aws eks describe-cluster --name dev \
  --query "cluster.resourcesVpcConfig.{public:endpointPublicAccess,private:endpointPrivateAccess}"
```

---

## Cross-AZ traffic and cost

The most frequent cloud networking surprise at scale is the cross-AZ traffic bill. AWS, GCP, and Azure charge for inter-AZ traffic.

**The problem scenario:**

```
AZ a: pod-frontend (10.0.1.10)  →  AZ b: pod-backend (10.0.2.20)
                                   ↑
                        $0.01/GB for each GB crossing the AZ boundary
```

At 100 GB/day of cross-AZ traffic: $1/day → $30/month. At 1 TB/day: $300/month. This grows unbounded with cluster size.

### Mitigation 1: topology-aware routing

Kubernetes topology-aware routing (stable 1.27) hints kube-proxy to prefer endpoints in the same zone as the calling pod:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend
  annotations:
    service.kubernetes.io/topology-mode: "Auto"
spec:
  selector:
    app: backend
  ports:
    - port: 80
```

With `topology-mode: Auto`, the EndpointSlice controller adds zone hints. kube-proxy prefers in-zone endpoints when zone capacity is proportional. Requires `TopologyAwareHints` feature gate (on by default since 1.23).

### Mitigation 2: topology spread constraints

Spread pods across AZs to reduce the probability of cross-AZ paths:

```yaml
spec:
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app: backend
```

This is a scheduling constraint, not a routing hint. Combine both for maximum effect.

### Mitigation 3: nodeSelector/affinity for co-location

When a producer and consumer service are tightly coupled, co-locate them in the same AZ by pinning both to the same node group:

```yaml
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: topology.kubernetes.io/zone
              operator: In
              values: [us-east-1a]
```

`preferred` (not `required`) keeps scheduling from failing if capacity is unavailable in that zone.

---

## Debugging: pod IP exhaustion, LB stuck pending, cross-AZ cost blowup

### Pod IP exhaustion (EKS VPC CNI)

Symptom: new pods are `Pending`, `describe` shows:

```
Warning  FailedScheduling  pod/myapp-xxx  0/3 nodes are available:
  3 Insufficient pods.
```

Or pods scheduled but stuck `ContainerCreating` with `failed to assign an IP address to container`:

```bash
# Check VPC CNI on the affected node
kubectl -n kube-system logs ds/aws-node -c aws-node --tail=50 | grep -iE "error|exhaust|ip"

# Check how many IPs are pre-warmed vs used on the node
kubectl get node <node-name> -o jsonpath='{.status.allocatable.pods}'
# Compare: kubectl get pods --all-namespaces --field-selector spec.nodeName=<node-name> | wc -l

# Check ENI / IP counts in the VPC CNI status
kubectl -n kube-system exec ds/aws-node -c aws-node -- \
  /app/grpc-health-probe -addr=:50051
# Or: use `describe node` → Capacity.pods vs Allocatable.pods

# If the subnet itself is exhausted (not just the node):
aws ec2 describe-subnets --subnet-ids subnet-xxx \
  --query 'Subnets[0].AvailableIpAddressCount'
```

Fixes:
1. Enable prefix delegation (`ENABLE_PREFIX_DELEGATION=true`) for per-node IP exhaustion.
2. For subnet exhaustion: add a new CIDR block to the VPC and subnet, or create additional node groups in larger subnets.
3. Short-term: use a secondary IPv6 CIDR (AWS supports IPv6 dual-stack in VPC CNI).

### LoadBalancer Service stuck `<pending>` external IP

```bash
# 1. Check Service events
kubectl describe service my-app | tail -20
# Look for: "Error creating load balancer", "Timeout waiting for load balancer"

# 2. Check the cloud-controller-manager logs (on EKS, it runs in the managed control plane)
#    You won't have direct access; instead look at CloudTrail
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=CreateLoadBalancer \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)

# 3. Verify the node IAM role has the LB permissions
#    Required policies for the cloud controller to create ELBs:
#    - AmazonEKSClusterPolicy (contains elasticloadbalancing:* permissions)
#    Check:
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::ACCOUNT:role/NODE_ROLE \
  --action-names elasticloadbalancing:CreateLoadBalancer \
  --query 'EvaluationResults[0].EvalDecision'

# 4. On GKE: check if the firewall rule was created
gcloud compute firewall-rules list --filter="name~k8s"
# A missing firewall rule from GKE → Service can provision but traffic doesn't reach pods

# 5. On AKS: check if the subnet has enough IPs for the LB frontend
az network vnet subnet show -g my-rg --vnet-name my-vnet -n my-subnet \
  --query availableIpAddressCount
```

The most common EKS cause: the IAM role on the cluster (not the node) is missing `elasticloadbalancing:*`. Check the cluster role, not the node role.

### Cross-AZ cost blowup

When a cost spike appears on the bill under "Data Transfer - Regional":

```bash
# Find which pods are sending cross-AZ traffic
# EKS with VPC Flow Logs:
# Flows with src-az != dst-az where src is a pod IP → cross-AZ traffic

# Start with: are your pods in one AZ talking to services in another?
kubectl get pods -o wide --all-namespaces | awk '{print $1, $2, $8}' | sort -k3
# (namespace, pod name, node name) → correlate node to AZ via:
kubectl get nodes -L topology.kubernetes.io/zone

# Quantify with metrics-server or Prometheus:
# container_network_transmit_bytes_total filtered by source_zone != destination_zone

# Quick check: is topology-aware routing enabled?
kubectl get svc my-backend -o jsonpath='{.metadata.annotations.service\.kubernetes\.io/topology-mode}'
# If empty → not enabled; add the annotation and redeploy endpoints

# Verify EndpointSlice hints are being generated:
kubectl get endpointslices -l kubernetes.io/service-name=my-backend -o yaml | grep hints
```

If topology hints show `zone: us-east-1a` for some endpoints but pods are still crossing zones, check whether the serving zone's capacity is proportional enough to activate the hint (GKE and EKS both require at least 3 pods per zone for hints to activate reliably).

---

## Checkpoint

You are ready for the next module when you can:

1. Calculate the maximum number of pods for a `t3.large` (3 ENIs, 12 IPs per ENI) using VPC CNI without prefix delegation, and with prefix delegation.
2. A pod is stuck `ContainerCreating` with `failed to assign IP`. Describe the 3-step diagnostic sequence, distinguishing node-level exhaustion from subnet-level exhaustion.
3. A `Service type: LoadBalancer` has been `<pending>` for 10 minutes on EKS. Name the two most common causes, and the exact IAM API call to verify the second one.
4. You have a frontend Deployment (30 replicas) and a backend Deployment (30 replicas), both spread across 3 AZs. Every frontend request calls the backend. Cross-AZ costs are $500/month. Name two configuration changes — one scheduling, one routing — that would reduce this.
5. What is the security difference between a public EKS cluster and a private one? Under what circumstance does a private cluster still expose the API server?
6. Explain what GKE NEGs do differently from `kube-proxy` iptables for load balancer traffic, and why it matters for latency and pod-level observability.

➡ Next up: **Autoscaling** — Cluster Autoscaler, Karpenter, HPA with custom metrics, and KEDA.
