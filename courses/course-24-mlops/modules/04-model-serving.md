# Model Serving

> **Module 04 · Course 24** — Training is a solved problem by the time you reach production. Serving is where ML meets distributed systems, and the failure modes are different in kind: cold starts, p99 cliffs, silent version mismatches, OOM from a request size you didn't test. This module is about building serving infrastructure that you can reason about under load.

---

## Offline/batch vs online/real-time

The choice of serving mode drives every other architectural decision.

```
         Latency          Throughput        Freshness         Common use
         ─────────────    ─────────────     ────────────      ──────────────────────
Batch    minutes–hours    very high         stale by hours    overnight recommendations,
                          (process all      (acceptable)      fraud scoring for EOD
                          records at once)                    settlements, report gen

Online   < 100 ms p99     moderate          current           real-time fraud scoring,
(sync)   < 10 ms p99      (bounded by        (< 1s SLO)       content ranking at request,
         for fast models  infra)                              dynamic pricing, search

Async    seconds          high              near-real-time    background enrichment,
(queue)  (accepted by     (decoupled        (acceptable)      async classification,
         caller)          producer)                           GPU inference offload
```

Most teams start with batch because it is easy and end up wanting online because stakeholders want real-time results. The migration is painful when your pipeline has hardcoded batch assumptions. Design batch pipelines as if they might eventually need a streaming version.

---

## REST vs gRPC for model serving

Both are valid. Know when each wins:

| Dimension | REST (JSON over HTTP/1.1) | gRPC (Protobuf over HTTP/2) |
|-----------|--------------------------|----------------------------|
| Payload | JSON: human-readable, large for float arrays | Protobuf: compact, typed, ~3–10× smaller for float vectors |
| Latency | higher for large tensors (JSON parse overhead) | lower; binary framing + multiplexing over one connection |
| Streaming | SSE / chunked — awkward | native bidirectional streaming |
| Tooling | curl, Postman, every load balancer | requires a gRPC client; harder to debug without grpcurl |
| Service mesh | L7 routing, Envoy, Istio all speak it natively | gRPC is HTTP/2; Envoy and Istio support it; some older LBs don't |
| Best for | public APIs, simple inference endpoints, teams new to the stack | high-throughput internal inference, embedding services, streaming |

For a model serving ≤ 1KB input vectors at < 10K RPS, REST is almost always the right choice due to tooling ergonomics. Switch to gRPC when profiling shows JSON serialisation in the critical path.

---

## Request batching

A single inference request uses a GPU inefficiently — the GPU processes a batch in roughly the same time as a single sample. Batching multiplies throughput without proportional latency cost.

```
                     ┌─────────────────────────────────┐
request A ──────────►│                                 │
request B ──────────►│   Batcher (max_batch_size=32,   │──► model.predict(batch)
request C ──────────►│   max_delay_ms=5)               │
...                  │                                 │
                     └─────────────────────────────────┘
```

Three batching strategies:

**1. Static batching** — the client sends a batch. Simple; forces batch assembly onto the caller. Common in offline scoring.

**2. Dynamic (continuous) batching** — the server accumulates requests for up to `max_delay_ms` ms or until `max_batch_size` is reached. Standard in frameworks like Triton, TorchServe, and BentoML.

**3. In-flight batching (iteration-level batching)** — for autoregressive models like LLMs; new requests join an ongoing forward pass at a sequence boundary. Specific to generative models.

```python
# BentoML dynamic batching example
import bentoml
from bentoml.io import NumpyNdarray

svc = bentoml.Service("fraud_scorer")

runner = bentoml.sklearn.get("fraud-classifier:latest").to_runner()
svc.add_runner(runner)

@svc.api(input=NumpyNdarray(), output=NumpyNdarray(), max_batch_size=64, max_latency_ms=5)
async def predict(input_array):
    return await runner.predict.async_run(input_array)
```

The `max_latency_ms=5` trades 5 ms of added latency per request for a ~32× throughput multiplier on a busy server. Right-size `max_batch_size` to your model's GPU memory limit — too large and you get OOM, too small and you lose the multiplier.

---

## Autoscaling and cold starts

### Autoscaling

Kubernetes HPA (Horizontal Pod Autoscaler) scales on CPU/memory or custom metrics. For model serving, custom metrics are almost always better:

```yaml
# HPA scaling on requests-per-second via KEDA or Prometheus adapter
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: fraud-scorer-hpa
  namespace: dojo-serving
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: fraud-scorer
  minReplicas: 2
  maxReplicas: 20
  metrics:
  - type: Pods
    pods:
      metric:
        name: inference_requests_per_second  # custom Prometheus metric
      target:
        type: AverageValue
        averageValue: "50"                   # scale up when > 50 RPS per pod
```

Keep `minReplicas: 2` for any production serving deployment — one replica means any rolling update or node eviction causes a hard availability gap.

### Cold starts — the latency cliff

A cold start occurs when a new pod must:
1. pull the image (if not cached on the node)
2. load the model binary from storage (S3 / MLflow artefact store) into RAM
3. warm up the first prediction (JIT compilation for PyTorch, XGBoost tree loading)

On a large model, this chain can take 30–90 seconds. Every autoscaling event that creates a pod has this cost.

**Mitigations:**

| Strategy | How |
|----------|-----|
| Pre-pull images | Use a DaemonSet or node pre-pull annotation; pin model image to a tag, not `:latest` |
| Init containers for model download | Download the model from S3 in an init container; main container starts with model already on shared volume |
| Warm-up requests after readiness | Send synthetic requests in `postStart` or via a startup probe that only passes after the first batch succeeds |
| Keep-alive (min replicas) | `minReplicas: 2` ensures you never scale from zero; scale-to-zero is only acceptable for batch/async paths |

```yaml
# pod spec: init container downloads the model before the serving container starts
initContainers:
- name: download-model
  image: amazon/aws-cli:2.17.0
  command: ["aws", "s3", "cp", "s3://models/churn-classifier/v3/model.pkl", "/model/model.pkl"]
  volumeMounts:
  - name: model-volume
    mountPath: /model
containers:
- name: fraud-scorer
  image: myregistry/fraud-scorer:1.4.2
  volumeMounts:
  - name: model-volume
    mountPath: /model
  readinessProbe:
    httpGet:
      path: /healthz
      port: 8080
    initialDelaySeconds: 5
    periodSeconds: 2
volumes:
- name: model-volume
  emptyDir: {}
```

---

## Serving frameworks: KServe, BentoML, Seldon

| Framework | Best for | Key concept |
|-----------|---------|------------|
| **KServe** (formerly KFServing) | Kubernetes-native serving on top of Knative; multi-model, canary, explainers, data plane | `InferenceService` CRD; pluggable runtimes (Triton, MLserver, custom); scales to zero via Knative |
| **BentoML** | Pythonic model serving; easy local dev → cloud; supports dynamic batching, custom runners | `bentoml.Service` wraps any Python model; `bentoml build` packages to an OCI image |
| **Seldon Core** | Enterprise; graph pipelines (A/B, shadow, multi-stage); Kubernetes operator | `SeldonDeployment` CRD; built-in explainability; requires Seldon Operator CRD installed |
| **Triton Inference Server** | High-throughput GPU serving for PyTorch, TensorFlow, ONNX, TensorRT | Server-side batching, model ensemble, gRPC + HTTP2; needs a model repository layout |

For the challenges in this course you will use **BentoML** (simpler local dev) and **KServe** (the Kubernetes-native path). The concepts transfer directly to Triton and Seldon.

### KServe InferenceService example

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: fraud-classifier
  namespace: dojo-serving
spec:
  predictor:
    sklearn:
      storageUri: "s3://models/churn-classifier/v3"
      resources:
        requests:
          cpu: "500m"
          memory: "512Mi"
        limits:
          cpu: "2"
          memory: "2Gi"
      # canary: route 10% of traffic to a new challenger
  canaryTrafficPercent: 10
  transformer:                   # optional: pre/post-process in a sidecar
    containers:
    - name: transformer
      image: myregistry/fraud-transformer:1.0.0
```

KServe handles the Kubernetes Service, HPA, and Knative revision management for you. The `storageUri` is the MLflow or S3 path; KServe initialises the model via an init container pattern internally.

---

## GPU serving

GPU inference changes three constraints you might ignore on CPU:

**Memory:** a model loaded onto GPU lives in VRAM. VRAM is not pageable. If `batch_size × feature_tensor_size > available_VRAM`, the request OOM-kills the serving process, taking down all in-flight requests on that worker.

```python
# Explicit VRAM sizing before deploying
import torch
model = torch.load("model.pt", map_location="cuda")
print(torch.cuda.memory_allocated() / 1e9, "GB allocated after model load")
# Calculate: max_batch_size × input_tensor_bytes + model_size + activations
# Leave 20% headroom for activations and framework overhead
```

**Throughput vs latency tradeoff:** on GPU, batch_size=1 has almost the same latency as batch_size=32 for many model architectures. Batching is free until you fill VRAM. Set `max_batch_size` to the largest value that fits with 20% VRAM headroom.

**Mixed-precision:** FP16 (half-precision) inference halves VRAM use and is 2–3× faster on NVIDIA Ampere/Hopper with negligible accuracy loss for most models:

```python
import torch
model = model.half()              # convert to FP16
inputs = inputs.half()
with torch.no_grad():
    output = model(inputs)
```

For production, `torch.compile()` (PyTorch 2.x) further optimises the compute graph:

```python
model = torch.compile(model, mode="reduce-overhead")  # ~1.5-2× speedup, 10s first-run compilation
```

The first request after a cold start will be slower due to JIT compilation. This is expected and should be excluded from SLO measurements.

---

## Debugging Model Serving

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| p99 latency spikes every N minutes | Autoscaler is creating new pods (cold start penalty); or a GC pause in a JVM-backed framework | Profile with `kubectl top pod`; check HPA event log; use min_replicas≥2; implement a warm-up request in the readiness probe |
| Serving pod OOMKilled shortly after high traffic | Batch size too large for container memory limit; or model loaded multiple times (one per worker thread) | Load the model once per process, share across threads; calculate peak memory = batch_size × tensor_size + model_size + 20%; set container `limits.memory` accordingly |
| Model returns predictions that look plausible but are subtly wrong | Version mismatch — the serving container has a different model version than the registry says is Production | Tag every container image with the MLflow model version; assert `model.metadata.run_id` at startup equals the expected run ID from an env var |
| Requests time out under moderate load but GPU utilisation is low | Dynamic batching not configured; each request hits the model individually, serialising GPU work | Enable dynamic batching in BentoML/Triton; increase `max_batch_size` until GPU utilisation rises above 60% |
| gRPC calls succeed but REST calls return 400 | Input shape or dtype differs between REST (JSON float → Python float) and gRPC (Protobuf float32 → numpy float32) | Normalise input dtype in the preprocessing layer; log the raw request tensor shape on both paths |
| Cold start takes 90+ seconds after scale-up | Model is being downloaded from S3 at container start; large model | Use an init container to pre-download; or bake the model into the image (acceptable for ≤500 MB) |

> **War story.** A real-time fraud scoring service at a previous company ran at a comfortable p50 of 8 ms for months. One Thursday, during a promotional event, p99 jumped to 4 seconds and the on-call team got paged. The root cause took two hours to find: HPA had scaled from 3 pods to 18 pods in under a minute. Each new pod was downloading a 400 MB model from S3 at startup (the download took ~80 seconds on the cluster's network). For 80 seconds per new pod, traffic was being routed to pods that had not yet finished loading, so those pods queued every request while the model loaded. The fix was an init container that blocked the serving container from starting until the model download completed, combined with a readiness probe that did a dry-run inference and only returned 200 after the first successful prediction. Cold start time became a first-class metric on the dashboard after that — it had never been tracked before.

---

## Checkpoint

You are ready for the challenges in this course when you can, without looking anything up:

1. Describe the three serving modes (batch, online-sync, async-queue) and name one ML use case where each is the right choice.
2. List three concrete differences between REST and gRPC for model serving and state when you would choose gRPC over REST.
3. Explain dynamic batching: what `max_batch_size` and `max_latency_ms` do, and write a BentoML `@svc.api` decorator that enables it.
4. Describe the cold start chain (image pull → model load → warm-up) and give one mitigation at each stage.
5. Write the Kubernetes HPA manifest fields that set a custom RPS metric target with `minReplicas: 2` and `maxReplicas: 20`.
6. Explain why OOM is more destructive in a GPU serving pod than in a CPU pod, and derive the formula for the maximum safe batch size given a VRAM budget.
7. Describe the three KServe, BentoML, and Triton trade-offs and state which one you would reach for first for: (a) a simple scikit-learn model in a Kubernetes cluster, (b) a high-throughput PyTorch model needing GPU serving.
8. Given a p99 latency spike that correlates with HPA scale-out events, name the root cause and write the pod spec change that prevents requests from reaching a pod before its model is loaded.

➡ Next up: the **Model Serving** challenge — you will wrap a trained scikit-learn model in a FastAPI endpoint, containerise it, and deploy it to the dojo cluster via a KServe-style pattern.
