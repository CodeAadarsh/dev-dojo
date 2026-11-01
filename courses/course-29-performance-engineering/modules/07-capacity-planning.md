# Capacity Planning & Cost

> **Module 07 · Course 29** — "We need more servers" is not a capacity plan. A capacity plan is a number: how many instances, what size, at what utilization target, to meet what SLO, at what cost per request. This module walks from load-test data to a defensible instance count, explains why the latency knee makes naive CPU-headroom math dangerous, and shows you how HPA targets translate to actual fleet size under traffic spikes.

This is the module you'll be glad you read during the week your service starts trending on the growth chart.

---

## From load test to instance count

The reliable path from "what do I deploy" to a number you'll trust under production load:

```
1. Measure: run a load test at increasing concurrency → record p50/p95/p99 latency and throughput
2. Find the knee: identify where latency begins to climb faster than throughput grows
3. Compute required replicas: instances = ceil(peak_rps / throughput_per_instance_at_target_util)
4. Add headroom: multiply by 1 / target_utilization (e.g. ÷ 0.7 for 70% target)
5. Validate: shadow test or canary at production traffic; verify p99 SLO holds
```

### Step 1: the load test

Use a load generator that models your workload correctly. Two common mistakes:

- **Closed-loop testing** (most naive tools): N virtual users each send a request and wait for the response before sending the next. At high latency, they send *fewer* requests, which caps observed load artificially. You think the system is saturated but you just slowed down the driver.
- **Open-loop testing** (correct for most services): requests arrive at a fixed rate regardless of response time. `wrk`, `k6`, `locust` with a fixed spawn rate, or Gatling's open model.

```bash
# open-loop with wrk2 — 1000 req/s for 60s, 50 concurrent connections
wrk2 -t4 -c50 -d60s -R1000 --latency http://localhost:8000/api/endpoint
```

The output you care about:
```
Latency Distribution
   50%    4.23ms
   75%    6.89ms
   90%   12.44ms
   99%   45.12ms
  99.9%  180.31ms

Requests/sec:   998.73   ← confirms open-loop rate was sustained
```

Record these at multiple rates: 500, 750, 1000, 1250, 1500 req/s. When p99 starts rising non-linearly, you've found the knee.

### Step 2: find the knee

Plot throughput on X, p99 latency on Y:

```
p99 latency (ms)
     |
  180|                                              *
     |                                         *
  100|                                    *
     |                             *
   50|                    *
     |         *
   20|   *  *
     |
     └──────────────────────────────────────── req/s
       500  750  1000  1250  1500  1750  2000
                         ↑
                     knee ≈ 1250 req/s (p99 starts inflecting)
```

The knee is the point past which latency climbs faster than the throughput gain justifies. For a latency-sensitive API, set your **operational ceiling** 20–30% below the knee. Here: 1000 req/s per instance.

### Step 3: compute instance count

```
peak_rps       = 8000 req/s  (from traffic forecast)
capacity_per_instance = 1000 req/s  (from load test, below knee)
target_utilization    = 0.70        (headroom policy)

raw_instances  = ceil(8000 / 1000) = 8
with_headroom  = ceil(8 / 0.70)    = 12 instances
```

Set `minReplicas = 12` in production, or set HPA to keep average CPU/custom metric at ≤ 70% and let it scale up from there.

---

## Headroom and the latency knee

The 70% target is not arbitrary. From the M/M/1 queueing model (previous module), at 70% utilization:

```
W_queue = (0.70 / (1 − 0.70)) × W_service = 2.33 × W_service
```

At 90%:
```
W_queue = (0.90 / 0.10) × W_service = 9× W_service
```

The ratio of queueing latency between 90% and 70% utilization is `9 / 2.33 ≈ 4×`. That 20-percentage-point difference is a 4× latency multiplier on the queued portion.

For latency-sensitive services (SLO < 100ms p99), target **≤ 70% CPU utilization** at peak traffic. For batch/analytics services with loose latency requirements, 85% is reasonable. For message queue consumers where throughput matters more than latency, 90%+ is fine.

> Headroom is not waste. It is your safety margin against traffic spikes, cold starts, GC pauses, and the fact that load tests never perfectly model production. The cost of the headroom capacity is almost always less than the cost of a single incident.

---

## Autoscaling targets

Kubernetes HPA scales on observed metrics vs a target. The scale-out formula:

```
desired_replicas = ceil(current_replicas × (current_metric_value / target_metric_value))
```

### CPU-based HPA

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-hpa
  namespace: dojo-perf
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  minReplicas: 3
  maxReplicas: 50
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70   # target 70% of the CPU request
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300   # wait 5 min before scaling down
      policies:
      - type: Percent
        value: 25
        periodSeconds: 60   # max 25% of replicas removed per minute
    scaleUp:
      stabilizationWindowSeconds: 0   # scale up immediately
      policies:
      - type: Pods
        value: 4
        periodSeconds: 15   # add at most 4 pods every 15s
```

**Why `averageUtilization: 70`?** The HPA measures utilization against the pod's `requests.cpu`. If `requests.cpu = 500m` and the pod consumes 350m, that's 70%. You must set accurate `requests` — if requests are too low, the HPA sees 140% utilization and panics; if too high, it never scales.

### Custom metric HPA (Prometheus + KEDA)

CPU is a proxy. For a queue consumer, the right metric is queue depth. For an HTTP API, it's requests-in-flight or request rate per replica.

```yaml
# KEDA ScaledObject — scales on Prometheus query
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: api-scaledobject
  namespace: dojo-perf
spec:
  scaleTargetRef:
    name: api
  minReplicaCount: 3
  maxReplicaCount: 50
  triggers:
  - type: prometheus
    metadata:
      serverAddress: http://prometheus.monitoring.svc:9090
      metricName: http_requests_in_flight
      threshold: "10"   # scale so that each replica handles ≤ 10 in-flight
      query: sum(http_requests_in_flight{job="api"})
```

KEDA is the right tool when: the signal isn't CPU (queue depth, in-flight count, custom latency SLO), or you need scale-to-zero.

---

## Cost per request

Understanding cost per request lets you compare optimization options in dollar terms, not just milliseconds.

```
cost_per_request = (monthly_instance_cost × replica_count) / (monthly_request_count)

example:
  t3.medium at $0.0416/hr = $30/month
  12 replicas            = $360/month
  8000 req/s × 86400 × 30 = 20.7 billion requests/month
  cost per request = $360 / 20.7B ≈ $0.000017 = 1.7 µ$/request
```

Two uses:

1. **Justify optimization work.** "Cutting replica count from 12 to 8 (from the caching module's improvements) saves $120/month × 12 months = $1440/year." Compare that to engineer-hours.
2. **Catch cost blowups early.** Set a cost-per-request alert. If it doubles, something regressed (a new N+1, a cache miss storm, a misconfigured HPA).

---

## Right-sizing

Right-sizing means setting `requests` and `limits` that match actual consumption, not theoretical maximums.

### Why wrong sizing hurts

- **Requests too high:** HPA sees low utilization and doesn't scale out when it should; you waste bin-packing capacity (the scheduler reserves CPU that's never used).
- **Limits too high:** CPU throttling never kicks in; a runaway process steals resources from neighbors. Memory limit too high + OOM → node pressure evictions.
- **Requests == Limits (Guaranteed QoS):** fine for latency-sensitive pods; but if limits are set generously "to be safe," you're wasting again.

### The right-sizing workflow

```bash
# 1. Run for 1 week in production with Vertical Pod Autoscaler in "Off" mode
#    (observe only — it recommends but does not apply):
kubectl apply -f vpa-recommender.yaml

# 2. After 7 days:
kubectl describe vpa api-vpa
# Look at:
#   Recommendation:
#     Container: api
#       Lower Bound: cpu: 180m, memory: 220Mi
#       Target:      cpu: 250m, memory: 290Mi
#       Upper Bound: cpu: 500m, memory: 500Mi

# 3. Set requests = Target, limits = Upper Bound × 1.2
#    (20% buffer above VPA upper bound for spikes)
```

For services that can't use VPA (StatefulSets, or it conflicts with your HPA), use `kubectl top pods --containers` sampled at peak hours and set requests at p95 of observed consumption.

---

## Load forecasting

### Why forecasting matters

Right-sizing and autoscaling handle current load. Forecasting handles: "do we have enough capacity for the Black Friday traffic spike we expect next month?"

### Simple linear extrapolation

```python
import numpy as np

# rps sampled daily over 30 days
days = np.arange(30)
rps  = np.array([1200, 1230, 1250, ...])   # your actual data

coeffs = np.polyfit(days, rps, 1)   # linear fit
growth_per_day = coeffs[0]

forecast_60d = np.polyval(coeffs, 60)
print(f"Forecast RPS in 60 days: {forecast_60d:.0f}")
print(f"Instances needed: {-(-forecast_60d // capacity_per_instance / target_utilization):.0f}")
```

For services with weekly seasonality, use a 7-day moving average before fitting, or Holt-Winters (available in `statsmodels`). For sudden step-changes (new customer onboarding, product launch), forecast from the step date, not history.

### Capacity headroom check before a major event

```
peak_expected_rps   = current_peak × spike_multiplier  (e.g. 3× for a campaign)
current_max_rps     = replicas × capacity_per_instance × target_utilization
headroom_ratio      = current_max_rps / peak_expected_rps

if headroom_ratio < 1.0:
    scale_out_before_event = ceil(peak_expected_rps / (capacity_per_instance × target_utilization))
```

Pre-scale before the event. HPA reaction time is 15–60 seconds and its scale-up rate is bounded — it can't add 40 replicas instantaneously. For predictable spikes, use a scheduled HPA or a pre-scale script triggered 10 minutes before the event window.

---

## Debugging Capacity & Cost

### Symptom → Cause → Fix

| Symptom | Likely cause | Diagnosis | Fix |
|---------|-------------|-----------|-----|
| Latency SLO breached during traffic spike even though CPU is < 80% | HPA scaling too slow; traffic spike exceeded addRate policy | Check HPA events: `kubectl describe hpa`; look at `scaleUp.policies.periodSeconds`; compare spike ramp-rate to add-rate | Tighten `scaleUp` policy (more pods per interval); or pre-scale before known spikes; or lower the target utilization |
| HPA oscillates — replicas bounce 10 → 15 → 10 → 15 every few minutes | `scaleDown` stabilization window too short; metric is noisy | `kubectl get hpa -w` — if count swings with period < 5 min, it's flapping | Set `scaleDown.stabilizationWindowSeconds: 300`; smooth the metric (rate over 5m window instead of instant) |
| Cloud bill is 2× what it was 3 months ago; no traffic growth | Memory leak causing OOM → pods restart with new nodes provisioned; or HPA `maxReplicas` was raised without a corresponding floor | `kubectl top nodes` — utilization per node vs billing; compare deployment replica history | Fix the leak; audit HPA limits; set node-level `ResourceQuota` per namespace |
| VPA recommends requests much lower than current setting, but reducing them causes SLO breach | Bursty traffic — VPA recommendation is average-based; bursts exceed the new limit causing CPU throttle | Enable CPU throttle metrics: `container_cpu_cfs_throttled_periods_total / container_cpu_cfs_periods_total`; if > 25% on bursts, requests are too low for burst profile | Use VPA Target (not Lower Bound) for requests; set limit = Upper Bound × 1.5; or switch to a Burstable QoS profile with request = p50, limit = p99 |
| Autoscaling works fine at moderate load but collapses under 3× spike | Scale-to-zero or minReplicas too low; cold start time > LB health check timeout | Simulate: `kubectl scale deploy api --replicas=0` and measure time to first-ready; compare to LB `unhealthyThreshold × checkInterval` | Set `minReplicas` high enough so HPA never needs to cold-start all capacity; pre-warm with scheduled scale |
| `kubectl top pods` shows wildly uneven CPU across replicas | Traffic is not balanced — sticky sessions, consistent hash imbalance, or pods on congested nodes | Compare per-pod RPS from access logs vs `kubectl top`; check node CPU with `kubectl top nodes` | Disable long-lived keep-alive affinity; set `sessionAffinity: None`; use LEAST_CONN load balancing at the ingress level |

> **War story.** A Kubernetes-based API at a SaaS I worked with had a Black Friday SLO breach despite an HPA set to 70% CPU target. Post-mortem revealed the HPA `scaleUp` policy was set to `value: 1, periodSeconds: 60` — it could add at most 1 replica per minute. The traffic spike went from 500 to 8000 req/s in 4 minutes. At 1 replica per minute, it added 4 replicas while needing 10 new ones. The service ran at 200% utilization for 20 minutes while the HPA crawled toward the right count. The fix was two lines of YAML: `value: 10, periodSeconds: 15` — add up to 10 pods every 15 seconds on the way up. The next traffic event, the fleet scaled from 8 to 50 replicas in under 3 minutes, and p99 never cracked 80ms. Scaling speed is a parameter, not a given.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Explain why closed-loop load testing underestimates saturation, and name the correct testing model for an HTTP API.
2. Draw (or describe precisely) what the throughput vs p99 latency curve looks like for a service approaching saturation, and identify the "knee."
3. Given: capacity_per_instance = 800 req/s, peak_rps = 6400, target utilization = 70% — compute the required instance count.
4. Write the HPA `behavior.scaleUp` stanza that adds up to 8 pods every 15 seconds and never delays on scale-up.
5. Explain why `requests.cpu` accuracy is critical for CPU-based HPA, and what happens when requests are set too high vs too low.
6. Compute cost per request for: 6 replicas of a $50/month instance serving 500 req/s.
7. Name the VPA mode that observes without modifying pods, and describe the right-sizing workflow using it.
8. Describe how to pre-scale a deployment before a predictable spike and why HPA alone is insufficient for fast ramps.
9. Diagnose HPA flapping: what metric pattern causes it, and what two knobs stop it?

➡ You've completed the core Performance Engineering module track. The companion challenges in this course will ask you to apply all seven modules to a running service under real load.
