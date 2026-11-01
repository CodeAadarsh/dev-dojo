# Scaling & Cost

> **Module 07 · Course 24** — A model serving 100 RPS on a single pod is a prototype. A model serving 100 RPS at p99 latency under 200 ms across availability zones, with GPU costs that don't exceed 30% of revenue, is a production system. The gap between the two is almost entirely infrastructure decisions. This module covers the ones that move the needle on cost and scale, with the math to back each one.

GPU hours are the most expensive line item in ML infrastructure. Getting this right is an SRE skill that maps directly to your org's COGS.

---

## GPU scheduling in Kubernetes

### Requesting GPUs

GPUs are a Kubernetes extended resource. Unlike CPU and memory, they are integer-only and non-overcommittable by default.

```yaml
resources:
  limits:
    nvidia.com/gpu: 1    # request exactly 1 GPU; fractional GPU is not available at this level
  requests:
    nvidia.com/gpu: 1    # requests must equal limits for GPU resources
```

A pod that requests a GPU is scheduled only to a node with that GPU available. Once scheduled, the GPU is *exclusively* assigned to that pod until it terminates. This is why GPU utilization is the critical metric — an idle pod holds a $2.50/hr asset doing nothing useful.

### Node labels for GPU type selection

Clusters with mixed GPU types use `nodeSelector` or `nodeAffinity` to target specific hardware:

```yaml
spec:
  nodeSelector:
    accelerator: nvidia-a10g   # or nvidia-v100, nvidia-t4, nvidia-a100, etc.
```

Inspect the available GPU labels:

```bash
kubectl get nodes -l accelerator --show-labels
kubectl describe node <gpu-node> | grep -A 10 "Labels:"
```

### GPU sharing — three mechanisms

A single NVIDIA GPU can be shared between multiple workloads. Which mechanism to use depends on the hardware and the isolation requirements.

| Mechanism | Hardware | Isolation | Use case |
|-----------|----------|-----------|---------|
| **MIG (Multi-Instance GPU)** | A100, H100 | Hard — separate memory and compute slices | Shared inference across teams; strong isolation needed |
| **MPS (Multi-Process Service)** | All NVIDIA | Soft — shared memory, concurrent kernels | Co-located inference workloads at the same trust level |
| **Time-slicing** | All NVIDIA (via device plugin) | None — time-based scheduling | Dev/test clusters; small models; highest sharing ratio |

**Time-slicing config** (NVIDIA device plugin ConfigMap):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nvidia-device-plugin-config
  namespace: kube-system
data:
  config.yaml: |
    version: v1
    sharing:
      timeSlicing:
        replicas: 4
```

With `replicas: 4`, the device plugin advertises `4 × (GPU count)` allocatable GPUs. Each pod gets a quarter of the GPU's scheduled time. Useful for inference workloads that are bursty and latency-tolerant; dangerous for training workloads where GPU contention creates unpredictable epoch times.

**MIG example** (A100, 7-way split into 1g.10gb slices):

```bash
# on the node — partition one A100 into 7 equal compute instances
nvidia-smi mig -cgi 1g.10gb,1g.10gb,1g.10gb,1g.10gb,1g.10gb,1g.10gb,1g.10gb -C
```

```yaml
resources:
  limits:
    nvidia.com/mig-1g.10gb: 1    # request one 10GB MIG slice
```

MIG is the right tool when you have an A100 and multiple inference workloads that need dedicated VRAM with hardware-level isolation — each MIG instance has its own memory controller and error containment.

---

## Autoscaling inference

### HPA on GPU utilization

The default Kubernetes HPA scales on CPU and memory. For inference workloads, the right signal is GPU utilization or request queue depth.

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: inference-hpa
  namespace: dojo-mlops
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: churn-inference
  minReplicas: 1
  maxReplicas: 8
  metrics:
  - type: Pods
    pods:
      metric:
        name: gpu_utilization_percent   # emitted by DCGM exporter → Prometheus → adapter
      target:
        type: AverageValue
        averageValue: "70"              # scale up when average GPU utilization > 70%
```

This requires the Prometheus Adapter mapping `gpu_utilization_percent` from DCGM metrics. The upstream metric name from DCGM is `DCGM_FI_DEV_GPU_UTIL`.

### KEDA for queue-depth scaling

KEDA (Kubernetes Event-Driven Autoscaler) scales on external event sources — ideal for inference workloads backed by a queue (Kafka, Redis Streams, SQS).

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: inference-keda
  namespace: dojo-mlops
spec:
  scaleTargetRef:
    name: churn-inference
  minReplicaCount: 0           # scale-to-zero: all pods terminate when queue is empty
  maxReplicaCount: 10
  triggers:
  - type: redis
    metadata:
      address: redis-svc:6379
      listName: inference-queue
      listLength: "5"          # scale up when queue depth per replica exceeds 5
```

`minReplicaCount: 0` is scale-to-zero: when the queue empties, all pods terminate. A cold-start latency penalty is paid on the first request after a zero period — acceptable for async inference (batch scoring, nightly jobs), not for synchronous serving with a latency SLO.

### Scale-to-zero decision framework

| Scenario | Tool | Cold start | Acceptable when |
|----------|------|-----------|----------------|
| Async batch scoring | KEDA + queue | 30–120 s | First request waits; SLA is throughput, not latency |
| Synchronous model API | KEDA + `minReplicaCount: 1` | N/A — never zero | Always hot path |
| Dev/test inference | Knative Serving | 5–30 s (if weights cached) | Internal tool; no latency SLO |

The ROI math on scale-to-zero: if a GPU node costs $2.50/hr and your model handles 10 requests per day at 1 minute each, idle time is 23 hours 50 minutes. At full cost that is $5.95/day; scale-to-zero reduces it to under $0.25 (just the cold-start and active minutes). The ROI is immediate for low-volume async workloads.

---

## Caching and feature precomputation

### Inference result caching

A model call that takes 80 ms can be replaced by a cache lookup that takes 1 ms if the (input, prediction) pair was recently seen.

**Semantic caching** — cache on the exact input hash. Works when inputs repeat (a user re-requests the same recommendation, the same document is classified twice in short succession).

```python
import hashlib, json, redis

r = redis.Redis(host="redis-svc", port=6379)

def predict_with_cache(features: dict) -> float:
    key    = "pred:" + hashlib.sha256(
        json.dumps(features, sort_keys=True).encode()
    ).hexdigest()
    cached = r.get(key)
    if cached:
        return float(cached)
    score = model.predict_proba([list(features.values())])[0, 1]
    r.setex(key, 3600, str(score))   # TTL 1 hour — predictions stale after
    return score
```

### Feature precomputation (materialization)

Compute features for known entities (users, products, documents) in batch and store in a low-latency store. At inference time, look up precomputed features rather than running the full feature pipeline on the hot path.

```
  Batch job (hourly) ──► compute features for all active users ──► write to Redis
                                                                         │
  Inference request ──► fetch features from Redis (1 ms) ──► model ──► response
                        (instead of: query DB → aggregate → transform → 200 ms)
```

This pattern is the key to sub-10 ms serving latency for models with heavy feature engineering. The operational cost: you run a materialization job, you need a freshness SLO on that job, and stale features can silently degrade predictions — the same way a misconfigured join would in a traditional service.

---

## Vector DBs at scale

### ANN algorithms

Approximate Nearest Neighbor (ANN) search trades recall for latency. The core algorithms:

| Algorithm | Index structure | Build time | Query time | Best for |
|-----------|----------------|-----------|-----------|---------|
| **HNSW** | Hierarchical navigable small-world graph | Slow (minutes for 10M vectors) | Fast (< 5 ms at ef=64) | High-recall online search |
| **IVF** (Inverted File) | Coarse quantization + inverted lists | Medium | Medium | Balance of build cost and recall |
| **PQ** (Product Quantization) | Subspace compression | Fast | Fastest | High volume, some recall loss acceptable |
| **IVF+PQ** | IVF partitioning + PQ compression | Medium | Fast | Production at scale (Faiss default) |

The key HNSW hyperparameters:

```python
import faiss

d  = 768    # embedding dimension (BERT-base)
M  = 32     # connections per node in the graph — higher = better recall, more RAM
ef_construction = 200   # search depth during build — higher = better recall, slower build

index = faiss.IndexHNSWFlat(d, M)
index.hnsw.efConstruction = ef_construction
index.hnsw.efSearch = 64   # query-time depth — the lever for the recall/latency tradeoff
```

**Recall vs latency calibration curve:**

```
  efSearch= 16:  recall@10=0.82, latency=1.2 ms
  efSearch= 64:  recall@10=0.95, latency=3.8 ms
  efSearch=200:  recall@10=0.99, latency=11  ms
```

Pick `efSearch` against your recall SLO, then verify the resulting latency is within budget. They are inversely coupled — you cannot have both maximum recall and minimum latency simultaneously. A 95% recall target at typical embedding dimensions is usually achievable under 5 ms with HNSW.

### Sharding at scale

A single HNSW index for 100M vectors at dimension 768 requires roughly 60 GB of RAM. At scale, shard by:

- **Random sharding**: distribute vectors by `id % num_shards`. Simple, balanced load. A query hits all shards in parallel, then merges top-K results.
- **Cluster sharding**: k-means cluster the corpus; each shard holds a cluster. A query only hits shards whose cluster centroid is within distance `r` of the query vector. Reduces fan-out at the cost of build complexity and a partial-coverage risk at cluster boundaries.

For most RAG-at-scale setups, random sharding with 8–16 shards, each backed by an HNSW index on a Kubernetes StatefulSet, is the operational sweet spot:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: vector-index
  namespace: dojo-mlops
spec:
  replicas: 8
  serviceName: vector-index
  template:
    spec:
      containers:
      - name: index-server
        image: faiss-server:0.7.4
        resources:
          requests:
            memory: "8Gi"
          limits:
            memory: "10Gi"
        env:
        - name: SHARD_ID
          valueFrom:
            fieldRef:
              fieldPath: "metadata.annotations['apps.kubernetes.io/pod-index']"
```

---

## Inference cost math

Before buying more GPUs, run the numbers.

**Batch capacity on a single GPU:**

```
  GPU memory:               40 GB   (A100-40G)
  Model weights (FP16):     13 GB   (a 7B parameter model at 2 bytes/param)
  KV cache per token:        ~2 MB  (at typical context + attention heads)
  Available for batching:   40 - 13 = 27 GB
  Max batch at 512 tokens:  27 GB / (2 MB × 512) ≈ 26 concurrent requests
```

**Cost per inference:**

```
  A100 on-demand (GCP us-central1):  $3.67/hr
  Usable batch size:                 26 concurrent
  Throughput:                        ~2 000 tok/s  (7B model, FP16, A100)
  Cost per 1M tokens:                ($3.67/hr) / (2 000 tok/s × 3 600 s/hr) × 1 000 000 ≈ $0.51
```

This is why batch size matters: if you serve at batch size 1 (one request at a time), you pay 26x more per token than at full batch. Every empty slot in a batch is wasted GPU time.

**Decision framework — cost levers ranked by impact:**

| Cost lever | Impact | Implementation complexity |
|-----------|--------|--------------------------|
| Increase batch size | High — linear cost reduction | Low — serving config change |
| Quantize FP16 → INT8 | High — 50% memory freed, doubles usable batch | Medium — model re-export required |
| Scale-to-zero off-peak | High — eliminates idle GPU hours | Medium — KEDA setup |
| Knowledge distillation to smaller model | Very high — smaller GPU class | High — full retrain |
| Spot / preemptible instances | Medium (30–70% discount) | Medium — handle preemption gracefully |

---

## Quantization and distillation

### Quantization

Quantization reduces model weight precision to fit more weights in GPU memory and run faster matrix multiplications.

| Precision | Memory for 7B params | Relative inference speed | Accuracy loss |
|-----------|---------------------|--------------------------|--------------|
| FP32 | 28 GB | 1× baseline | Baseline |
| FP16 / BF16 | 14 GB | ~2× | Negligible |
| INT8 (bitsandbytes) | 7 GB | ~1.5× | Small (< 1% on most benchmarks) |
| INT4 (GPTQ / AWQ) | 3.5 GB | ~2× | Small to moderate (model-dependent) |

```python
# load a model in 8-bit with bitsandbytes — Hugging Face Transformers integration
from transformers import AutoModelForCausalLM

model = AutoModelForCausalLM.from_pretrained(
    "mistralai/Mistral-7B-v0.1",
    load_in_8bit=True,
    device_map="auto",
)
```

INT8 with bitsandbytes has essentially no accuracy impact on most tasks and halves VRAM — a practical first step before ordering a larger GPU.

**GPTQ / AWQ for INT4.** GPTQ and AWQ are post-training quantization methods that calibrate weight rounding on a small calibration dataset to minimize quantization error. They achieve near-INT8 quality at INT4 memory:

```bash
# quantize to 4-bit using AutoGPTQ
python3 -m auto_gptq.convert \
  --pretrained_model_name_or_path mistralai/Mistral-7B-v0.1 \
  --dataset c4 \
  --bits 4 \
  --output_dir ./mistral-7b-gptq-4bit
```

### Knowledge distillation

Distillation trains a smaller *student* model to mimic a larger *teacher* model's output distribution (soft labels, not hard class labels). The student learns the teacher's uncertainty and internal reasoning, not just its final answers.

```
  teacher (7B params) ──► soft labels P(A)=0.7, P(B)=0.2, P(C)=0.1 ──► student (1B params) training
                                                                          objective: minimize KL(teacher || student)
```

When to use distillation vs quantization:

| Scenario | Use |
|----------|-----|
| Model too large for GPU memory, same GPU class | Quantization (INT8 / INT4) first |
| Need to reduce serving cost by 5–10× | Distillation — target a smaller architecture |
| Both memory and throughput constrained | Distill first, then quantize the student |
| Task-specific fine-tuned model already exists | Fine-tune a student on task data with a distillation loss term |

---

## Debugging Scaling & Cost

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| GPU utilization 20–30% despite high RPS | Batch size too small; inference server processing requests one at a time | Enable dynamic batching in TorchServe/Triton; set `max_batch_size` > 1 and `max_batch_delay_us` to allow batching window |
| GPU utilization near 0% but pod is running | Data loading bottleneck — CPU preprocessing starves the GPU | Profile with `torch.profiler`; move preprocessing to GPU tensors or add async DataLoader workers |
| Cost 3× monthly estimate | Autoscaler provisioned max replicas and got stuck; no scale-down | Check HPA/KEDA events; verify scale-down cooldown; check for stuck requests holding pods warm past their useful lifetime |
| Vector search p99 latency spikes but p50 is fine | `efSearch` too high for p99 budget; or GC pause on the index server JVM | Lower `efSearch`; tune JVM GC if Java-based (Weaviate, Elasticsearch); add a replica for load distribution |
| Model recall drops after shard rebalancing | Shards rebalanced without rebuilding the HNSW graph; approximate recall from the new layout is worse | Rebuild index after rebalancing; perform a blue-green swap so old index stays live until new one is verified |
| INT8 quantization causes latency increase, not decrease | bitsandbytes INT8 kernel not available for this GPU architecture; falling back to emulated INT8 | Check kernel availability for your GPU arch; use FP16 if no native INT8 kernel exists |
| Scale-to-zero pod takes 90 s to cold-start | Model weights are downloaded at container startup rather than baked into the image | Bake model weights into the container image or mount from a pre-populated PVC; startup should be container pull + weight load, not weight download |

> **War story.** At SAP, we deployed a RAG pipeline for internal documentation search with a FAISS HNSW index over 2M document chunks at dimension 1536 (ada-002 embeddings). p50 latency was 12 ms — excellent. p99 latency was 800 ms — unacceptable for a synchronous search path that blocked a user-facing API. The culprit was `efSearch=256` copied from a benchmark config paper, plus a single-threaded Python serving loop that couldn't overlap index lookups. The fix: lower `efSearch` to 64 (recall@10 dropped from 0.99 to 0.96 — acceptable for internal search), switch to Triton's FAISS backend (multi-threaded query handling), and run two replicas behind a service. p99 dropped to 38 ms. The lesson: benchmark configs optimize for recall on paper, not for latency on your hardware. Calibrate `efSearch` against your actual p99 target on your actual hardware. The paper's number is a starting point, not a production config.

---

## Checkpoint

You're solid on scaling and cost when you can, without looking anything up:

1. Explain why `requests == limits` is required for GPU resources in Kubernetes, and what happens to utilization when a pod holds a GPU but isn't running inference.
2. Name the three GPU sharing mechanisms, state which one is appropriate for a shared inference cluster where different teams have different trust levels, and explain why.
3. State the scale-to-zero cold-start trade-off: when is it acceptable and when is it not, in concrete operational terms?
4. Walk through the inference cost math: given GPU price per hour, batch size, and tokens per second, derive cost per 1M tokens.
5. Explain why increasing batch size reduces cost per inference, and name the single constraint that limits the maximum achievable batch size.
6. Compare INT8 quantization and knowledge distillation: when do you reach for each, and can they be combined on the same model?
7. A GPU pod is running at 20% utilization despite high RPS — name the two most likely causes and the diagnostic step for each.
8. An HNSW index has excellent recall but p99 latency is 500 ms — name two independent interventions, and state what each one costs in terms of recall or operational complexity.

➡ The **scaling-and-cost** module closes the core sequence for Course 24. The challenges ahead apply these concepts end-to-end in a running cluster.
