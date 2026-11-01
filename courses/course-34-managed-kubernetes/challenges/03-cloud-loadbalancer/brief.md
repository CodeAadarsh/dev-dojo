# Cloud LoadBalancer — Internal NLB with IP Target Mode

A payment microservice needs a load balancer that meets three hard requirements from the infra review:

1. **Internal only** — the LB must not be reachable from the public internet
2. **IP target mode** — traffic must route directly to pod IPs, bypassing node-level kube-proxy (required for Kubernetes Network Policies to work at the pod level)
3. **Cross-zone load balancing** — the service deploys across 3 AZs; without cross-zone, a pod-dense AZ will receive more traffic than a sparse AZ

You need to author the Kubernetes Service manifest with the correct AWS Load Balancer Controller annotations. No cloud account needed — `verify.sh` parses the YAML offline.

## Context

`setup.sh` creates a work directory:

```
~/.kube-dojo-work/03-cloud-loadbalancer/
└── service.yaml    # stub — complete the annotations
```

## Prerequisites

```bash
pip3 install pyyaml
```

## Background: ALB vs NLB vs GCLB and when to use each

Understanding which load balancer to request is the 80% of the job that's invisible in the manifest:

| Dimension | ALB (Layer 7) | NLB (Layer 4) | GCLB (GCP) |
|-----------|---------------|---------------|------------|
| Protocol | HTTP/HTTPS, gRPC | TCP, UDP, TLS | HTTP(S), TCP |
| Routing | Path, host, headers | Port only | URL map |
| Use case | Web APIs, fanout routing | Databases, raw TCP, low-latency | All GCP workloads |
| Target types | IP (pods) or Instance (nodes) | IP (pods) or Instance (nodes) | NEGs (pods) |
| Annotations controller | AWS LBC | AWS LBC (in-tree or LBC) | GKE NEG controller |

The payment service uses gRPC over mTLS — that's raw TCP from the LB's perspective, so NLB is correct. ALB terminates TLS and re-encrypts, which breaks the mTLS chain.

## Why IP target mode matters

**Instance mode** (default with in-tree LB controller): traffic hits the node's `NodePort`, then kube-proxy DNAT-s it to a pod. Network Policies are evaluated at the node level, not pod level. Source IP is the node IP, not the client IP.

**IP mode** (AWS LBC): traffic hits the pod IP directly via a VPC route. Network Policies work at the pod. Source IP preservation is correct. Health checks probe the pod directly — you get faster failure detection.

The annotation for IP mode: `service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip`

## Mission

Complete `service.yaml` so it satisfies all three requirements:

| Requirement | Annotation |
|-------------|------------|
| Internal NLB | `service.beta.kubernetes.io/aws-load-balancer-scheme: internal` |
| IP target mode | `service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip` |
| Cross-zone LB | `service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"` |

You also need to tell the AWS LBC which controller should handle the Service:

```
service.beta.kubernetes.io/aws-load-balancer-type: external
```

This annotation is what distinguishes an AWS LBC-managed NLB (`external`) from the legacy in-tree NLB (`nlb`). The in-tree controller does not support IP mode or cross-zone on EKS 1.27+.

## What the verifier checks

```
✓ service.yaml — kind: Service
✓ spec.type: LoadBalancer
✓ annotation: aws-load-balancer-scheme = internal
✓ annotation: aws-load-balancer-nlb-target-type = ip
✓ annotation: aws-load-balancer-cross-zone-load-balancing-enabled = "true"
✓ annotation: aws-load-balancer-type = external
```

## Verify

```bash
bash courses/course-34-managed-kubernetes/challenges/03-cloud-loadbalancer/verify.sh
```

All checks pass → flag printed.
