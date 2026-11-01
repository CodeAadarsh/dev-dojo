# Solution — Cloud LoadBalancer — Internal NLB with IP Target Mode

The flag is `KUBE{nlb_internal_cross_zone_ip}`.

## Complete `service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: payment-service
  namespace: payments
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
spec:
  type: LoadBalancer
  selector:
    app: payment
  ports:
    - name: grpc
      port: 443
      targetPort: 8443
      protocol: TCP
```

## Why each annotation is required

### `aws-load-balancer-type: external`

This is the dispatch annotation. Setting it to `external` tells the in-tree cloud controller to **ignore** this Service and hands control to the AWS Load Balancer Controller (a separate Deployment in `kube-system`). Without it, the in-tree controller provisions a Classic LB (ELB) — the pre-2017 controller that doesn't support IP mode or cross-zone.

The legacy in-tree values (`nlb`) still work on EKS < 1.27 but are deprecated. On 1.27+ the AWS LBC is required for NLB features.

### `aws-load-balancer-scheme: internal`

Determines whether the NLB is provisioned with a public or private DNS name / IP allocation. `internal` = VPC-internal, no IGW route, no public IP. `internet-facing` = publicly routable. The payment service must never be `internet-facing` — the VPC egress review would catch it, but the annotation is the preventive control.

### `aws-load-balancer-nlb-target-type: ip`

The target type controls how the NLB routes to your pods:

| Target type | How it works | Network Policy effective? | Source IP |
|-------------|-------------|--------------------------|-----------|
| `instance` | → NodePort → kube-proxy → pod | No (policy sees node IP) | SNAT'd to node |
| `ip` | → pod IP directly via VPC route | Yes (policy sees client IP) | Preserved |

IP mode requires ENI-based networking (VPC CNI on EKS, Cilium, Calico with VPC native routing). If you're using Flannel VXLAN you cannot use IP mode.

### `aws-load-balancer-cross-zone-load-balancing-enabled: "true"`

By default, each NLB node in AZ-A only routes to targets in AZ-A. If you have 5 pods in us-east-1a and 1 in us-east-1b, the AZ-1b node still receives 50% of the traffic — the single pod gets 50% of all traffic instead of the expected ~16%.

With cross-zone: each NLB node distributes evenly across all targets in all AZs. The trade-off is one extra cross-AZ hop on some requests (~1ms latency, and cross-AZ data transfer costs ~$0.01/GB on AWS). For a payment service that already tolerates cross-AZ latency in its DB tier, this is a no-brainer.

## ALB alternative (if the requirement allowed HTTP)

For an HTTP/gRPC service that doesn't need end-to-end mTLS:

```yaml
annotations:
  kubernetes.io/ingress.class: alb
  alb.ingress.kubernetes.io/scheme: internal
  alb.ingress.kubernetes.io/target-type: ip
  alb.ingress.kubernetes.io/load-balancer-attributes: routing.http2.enabled=true
```

But this requires an Ingress resource (not a Service), and the ALB terminates TLS — breaking the mTLS chain between the client and the pod. NLB passthrough is the right choice here.

## Hardening preview

1. **Add `aws-load-balancer-security-groups`** — restrict the NLB's SG to inbound from the specific CIDR/SG of your internal clients. Without this the NLB accepts from 0.0.0.0/0 inside the VPC.
2. **TLS on NLB** — add `aws-load-balancer-ssl-cert: arn:aws:acm:...` and `aws-load-balancer-backend-protocol: ssl` to have the NLB terminate TLS before hitting the pod (useful if the pod doesn't handle TLS).
3. **Preserve client IP** — NLB in IP mode preserves the original client IP by default. Double-check your app reads `RemoteAddr`, not `X-Forwarded-For` (which ALB sets, not NLB).
