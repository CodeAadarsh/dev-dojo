# Serving & Cost Engineering

> **Module 06 · Course 11** — A RAG pipeline that's correct but costs $4,000/month and p99-latencies your users into churning is not production-ready. This module is about the arithmetic and systems design that make LLM features economically viable.

Every LLM cost blowup follows the same pattern: something that worked on 100 requests/day was assumed to scale linearly to 100,000, and nobody did the math. Do the math now.

---

## Latency budgets

A web SLA of p99 ≤ 2 s means your entire stack — DB, retrieval, LLM, network — must fit inside that budget. LLMs are the most expensive and least predictable component.

```
End-to-end latency breakdown (RAG, synchronous):

  User sends request
  │
  ├── Input processing + embedding      ~50–100 ms  (local model / API)
  ├── Vector search (Chroma/Qdrant)     ~5–30 ms
  ├── Context assembly                  ~1–5 ms
  ├── LLM call (until first token)      ~300–1200 ms  ← TTFB (Time To First Byte)
  ├── LLM token streaming               ~50–150 ms/100 tokens
  └── Response serialisation             ~1–5 ms

Total (synchronous, non-cached):       ~500 ms – 2000 ms (p50)
                                       ~1500 ms – 5000 ms (p99, under load)
```

The TTFB (time to first byte / first token) is the biggest lever for *perceived* latency. Streaming closes the gap: even if total generation time is 3 s, the user starts reading at 300 ms. Always stream.

### Setting your budget

| Use case | Target p50 TTFB | Target p99 total | Primary lever |
|----------|----------------|-----------------|---------------|
| Chat / interactive UI | ≤ 400 ms | ≤ 2 s | Streaming + fast model |
| Search answer synthesis | ≤ 600 ms | ≤ 3 s | Semantic caching |
| Background report generation | ≤ 30 s | ≤ 120 s | Async job queue |
| Agent multi-step | ≤ 1 s/step | ≤ 30 s total | Parallel tool calls |

Track p50, p90, p99, and p999 separately. A spike at p999 that a user hits 0.1% of the time is still 1 in every 1000 requests — visible at scale.

---

## Streaming

Never send the full response synchronously if the user is waiting. SSE (Server-Sent Events) is the standard transport for LLM streaming from a web API.

### FastAPI SSE endpoint

```python
from fastapi import FastAPI
from fastapi.responses import StreamingResponse
import anthropic

app = FastAPI()
client = anthropic.Anthropic()

def rag_stream(query: str):
    context = retrieve_context(query)  # your retriever

    with client.messages.stream(
        model="claude-sonnet-4-5",
        max_tokens=1024,
        system="Answer using only the provided context.",
        messages=[{
            "role": "user",
            "content": f"Context:\n{context}\n\nQuestion: {query}"
        }]
    ) as stream:
        for text_delta in stream.text_stream:
            # SSE format: "data: <payload>\n\n"
            yield f"data: {text_delta}\n\n"
    yield "data: [DONE]\n\n"

@app.get("/ask")
def ask(query: str):
    return StreamingResponse(
        rag_stream(query),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",  # disable Nginx response buffering
        }
    )
```

### Client consumption (JavaScript)

```javascript
const evtSource = new EventSource(`/ask?query=${encodeURIComponent(q)}`);
let buffer = "";

evtSource.onmessage = (e) => {
    if (e.data === "[DONE]") { evtSource.close(); return; }
    buffer += e.data;
    document.getElementById("answer").textContent = buffer;
};
```

### Streaming pitfall: Nginx / load-balancer buffering

Proxies buffer responses by default. A 3 s streaming response looks like a 3 s synchronous response to the client if Nginx is buffering. Always set:

```nginx
proxy_buffering off;
proxy_cache off;
chunked_transfer_encoding on;
```

Kubernetes Ingress (nginx-ingress): annotate your Ingress with:

```yaml
annotations:
  nginx.ingress.kubernetes.io/proxy-buffering: "off"
  nginx.ingress.kubernetes.io/proxy-read-timeout: "120"
```

---

## Batching

Batching amortizes the per-request overhead (API call setup, scheduling) by grouping multiple inputs into a single LLM call. The tradeoff: higher throughput, higher latency per item.

### Static batching (offline / async)

Use for background pipelines where throughput matters and latency doesn't:

```python
import asyncio
from anthropic import AsyncAnthropic

async_client = AsyncAnthropic()

async def embed_batch(texts: list[str], batch_size: int = 50) -> list[list[float]]:
    results = []
    for i in range(0, len(texts), batch_size):
        batch = texts[i:i + batch_size]
        tasks = [embed_one(t) for t in batch]
        batch_results = await asyncio.gather(*tasks)
        results.extend(batch_results)
    return results
```

For embedding pipelines processing millions of chunks at index time, this is table stakes. Async gather at batch_size=50 saturates the API's rate limit cleanly.

### Dynamic batching (online / inference server)

For a high-throughput inference server (vLLM, Ollama with concurrent requests), the runtime handles batching internally. Your job is to send requests concurrently:

```python
from httpx import AsyncClient
import asyncio

async def batch_generate(prompts: list[str]) -> list[str]:
    async with AsyncClient(timeout=30) as http:
        tasks = [
            http.post("http://localhost:11434/api/generate", json={
                "model": "llama3.2:3b",
                "prompt": p,
                "stream": False,
            })
            for p in prompts
        ]
        responses = await asyncio.gather(*tasks)
    return [r.json()["response"] for r in responses]
```

Ollama's default `OLLAMA_NUM_PARALLEL=1` means it serialises requests. Set `OLLAMA_NUM_PARALLEL=4` (or higher, memory permitting) for actual concurrency on the Mac Mini's M2.

```bash
# Check current Ollama settings
launchctl list | grep ollama

# Increase parallel slots (add to /etc/launchd.conf or set in the service plist)
OLLAMA_NUM_PARALLEL=4 ollama serve
```

---

## Caching

### Exact caching

Hash the (model, messages, temperature=0) tuple. If seen before, return the cached response. Eliminates cost and latency entirely for repeated identical requests — surprisingly common in chatbots where users re-ask the same top-50 questions.

```python
import hashlib, json, time
from functools import lru_cache

# In-process cache (dev / single instance)
_cache: dict[str, dict] = {}

def exact_cache_key(model: str, messages: list[dict]) -> str:
    canonical = json.dumps({"model": model, "messages": messages}, sort_keys=True)
    return hashlib.sha256(canonical.encode()).hexdigest()

def cached_generate(model: str, messages: list[dict]) -> str:
    key = exact_cache_key(model, messages)
    if key in _cache:
        return _cache[key]["response"]

    response = client.messages.create(
        model=model, max_tokens=1024, messages=messages
    ).content[0].text

    _cache[key] = {"response": response, "ts": time.time()}
    return response
```

For multi-instance production, use Redis:

```python
import redis

r = redis.Redis(host="redis-service", port=6379, decode_responses=True)
TTL = 3600  # 1 hour

def redis_cached_generate(model: str, messages: list[dict]) -> str:
    key = f"llm:{exact_cache_key(model, messages)}"
    cached = r.get(key)
    if cached:
        return cached

    response = _call_llm(model, messages)
    r.set(key, response, ex=TTL)
    return response
```

### Semantic caching

Exact caching misses paraphrases. Semantic caching embeds the query and finds similar cached queries by cosine similarity.

```python
import numpy as np

# Simplified semantic cache
class SemanticCache:
    def __init__(self, threshold: float = 0.95):
        self.threshold = threshold
        self.entries: list[dict] = []  # {embedding, response, query}

    def lookup(self, query: str) -> str | None:
        q_emb = embed(query)
        for entry in self.entries:
            sim = np.dot(q_emb, entry["embedding"])
            if sim >= self.threshold:
                return entry["response"]
        return None

    def store(self, query: str, response: str) -> None:
        self.entries.append({
            "embedding": embed(query),
            "response": response,
            "query": query,
        })
```

Threshold 0.95 is tight — two phrasings of the same factual question. 0.90 risks returning a cached answer to a different question. Use Qdrant/Chroma for production (with proper ANN indexing), not a linear scan.

> **Semantic caching hit rates in the wild:** 20–35% for support bots (users ask the same 50 questions in many ways). Near 0% for document Q&A with unique document content. Measure before investing in the infrastructure.

---

## Ollama (local) vs. API tradeoffs

| Dimension | Ollama (Mac Mini M2 8GB) | API (Claude/GPT) |
|-----------|--------------------------|-----------------|
| Cost per token | ~$0 (electricity + hardware amortisation) | $0.25–$15 per M output tokens |
| Latency (TTFB) | ~300–800 ms (llama3.2:3b on M2) | ~200–500 ms (claude-haiku) |
| Quality ceiling | Limited by 7B/8B model quality | Full frontier model quality |
| Privacy | Data never leaves your machine | Data leaves your infra |
| Concurrency | Limited by M2 memory/bandwidth | API rate limits (but higher) |
| Availability | Your uptime, your ops burden | Provider SLA (typically 99.9%+) |

**Decision rule:**
- Ollama for: development, eval runs, high-frequency low-stakes tasks (embedding, classification, summarisation), privacy-sensitive data.
- API for: production customer-facing features, tasks requiring frontier reasoning (complex agents, code generation), low-volume high-quality tasks.

Hybrid: use Ollama for retrieval scoring and context compression, API only for final answer generation. This can reduce API token spend by 40–60% on a RAG pipeline.

---

## Token cost math

Don't estimate — calculate. Before building any feature, run the cost arithmetic.

```python
# Token cost calculator (adjust prices to current rates)
PRICING = {
    "claude-haiku-4-5":   {"input": 0.80,  "output": 4.00},   # $ per million tokens
    "claude-sonnet-4-5":  {"input": 3.00,  "output": 15.00},
    "claude-opus-4-5":    {"input": 15.00, "output": 75.00},
    "gpt-4o":             {"input": 2.50,  "output": 10.00},
    "gpt-4o-mini":        {"input": 0.15,  "output": 0.60},
}

def estimate_cost(
    model: str,
    input_tokens: int,
    output_tokens: int,
    requests_per_day: int,
) -> dict:
    p = PRICING[model]
    cost_per_req = (
        input_tokens / 1_000_000 * p["input"] +
        output_tokens / 1_000_000 * p["output"]
    )
    return {
        "per_request_usd": cost_per_req,
        "daily_usd": cost_per_req * requests_per_day,
        "monthly_usd": cost_per_req * requests_per_day * 30,
    }

# Example: RAG system with 2000 input tokens, 300 output tokens, 10k req/day
print(estimate_cost("claude-haiku-4-5", 2000, 300, 10_000))
# -> {'per_request_usd': 0.0028, 'daily_usd': 28.0, 'monthly_usd': 840.0}

print(estimate_cost("claude-sonnet-4-5", 2000, 300, 10_000))
# -> {'per_request_usd': 0.0105, 'daily_usd': 105.0, 'monthly_usd': 3150.0}
```

The biggest lever is **context length**. A RAG system that shoves 8,000 context tokens at every query instead of 2,000 is 4x more expensive before any other change. Measure average context length in production and set hard truncation limits.

### Prompt caching (Anthropic)

For system prompts and retrieved context that's identical across many requests, Anthropic's prompt caching reduces input token costs by ~90% for the cached portion:

```python
response = client.messages.create(
    model="claude-sonnet-4-5",
    max_tokens=1024,
    system=[
        {
            "type": "text",
            "text": long_system_prompt,
            "cache_control": {"type": "ephemeral"}  # cache this
        }
    ],
    messages=[{"role": "user", "content": user_query}]
)
# First call: full input price
# Subsequent calls within 5 min: 90% discount on the cached portion
```

For a 2000-token system prompt at 10k requests/day on claude-sonnet-4-5: without caching, $180/month; with caching, ~$20/month. Enable it everywhere your system prompt is static.

---

## Serving a RAG API on Kubernetes

A minimal production-grade RAG serving stack on Kubernetes:

```yaml
# rag-api Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rag-api
  namespace: dojo-rag
spec:
  replicas: 3
  selector:
    matchLabels:
      app: rag-api
  template:
    metadata:
      labels:
        app: rag-api
    spec:
      containers:
        - name: api
          image: your-registry/rag-api:1.3.2
          ports:
            - containerPort: 8000
          env:
            - name: ANTHROPIC_API_KEY
              valueFrom:
                secretKeyRef:
                  name: rag-api-secrets
                  key: anthropic_key
            - name: REDIS_URL
              value: "redis://redis-service:6379"
            - name: CHROMA_URL
              value: "http://chroma-service:8001"
          resources:
            requests:
              cpu: "250m"
              memory: "512Mi"
            limits:
              cpu: "1000m"
              memory: "1Gi"
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 15
            periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: rag-api
  namespace: dojo-rag
spec:
  selector:
    app: rag-api
  ports:
    - port: 80
      targetPort: 8000
---
# HPA: scale on CPU + custom request-queue depth metric
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: rag-api
  namespace: dojo-rag
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: rag-api
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
```

The Redis and Chroma services are separate Deployments. The API key lives in a Kubernetes Secret. `readinessProbe` ensures no traffic before the model client is warmed up. HPA scales at 60% CPU — aggressive enough to stay ahead of a traffic spike.

### `/health` endpoint

```python
@app.get("/health")
async def health():
    # Check that all dependencies are reachable
    checks = {}
    try:
        r.ping()
        checks["redis"] = "ok"
    except Exception as e:
        checks["redis"] = str(e)

    # Return 503 if any critical dep is down
    status = 200 if all(v == "ok" for v in checks.values()) else 503
    return JSONResponse({"status": checks}, status_code=status)
```

A health check that always returns 200 is a lie that will route traffic to a broken pod. Make it actually test dependencies.

---

## Debugging Serving & Cost

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| p99 latency spikes at load, p50 is fine | Connection pool exhaustion to LLM API or vector DB; requests queue | Increase `max_connections` in your HTTP client; add connection pool metrics; consider adding replicas |
| Cost grows super-linearly with request volume | Uncapped context length; cache not hitting; token counting bug | Log `input_tokens` per request; set hard context truncation; verify cache key generation |
| `context_length_exceeded` error | Input tokens exceed model's context window | Count tokens before the call (Anthropic: `client.messages.count_tokens`); truncate context, not the system prompt |
| Streaming appears to work locally but not in production | Nginx/ingress buffering; `X-Accel-Buffering` missing; keep-alive timeout too short | Add `nginx.ingress.kubernetes.io/proxy-buffering: "off"` and increase `proxy-read-timeout` |
| HPA scales pods up but p99 doesn't improve | Bottleneck is not CPU — it's downstream (LLM API rate limit, Redis connection count) | Check rate limit errors in logs; add exponential backoff + retry; switch to per-user rate limiting at the API layer |
| Exact cache hit rate is 0% in production | Cache key includes timestamps, request IDs, or non-deterministic fields | Inspect cache key contents; ensure only (model, messages, temperature) are keyed |

### Exact diagnostic commands

```bash
# Token usage per request (tail your API logs)
kubectl -n dojo-rag logs -l app=rag-api --tail=100 | grep '"input_tokens"'

# p99 latency from your FastAPI access log (if you log request duration)
kubectl -n dojo-rag logs -l app=rag-api --tail=10000 \
    | grep '"duration_ms"' \
    | python3 -I -c "
import sys, json
durations = [json.loads(l)['duration_ms'] for l in sys.stdin if 'duration_ms' in l]
durations.sort()
n = len(durations)
print(f'p50: {durations[n//2]:.0f}ms  p99: {durations[int(n*0.99)]:.0f}ms  n={n}')
"

# Check Redis cache hit rate
kubectl -n dojo-rag exec -it deploy/redis -- redis-cli info stats \
    | grep -E 'keyspace_hits|keyspace_misses'

# Count context_length_exceeded errors last 1h
kubectl -n dojo-rag logs -l app=rag-api --since=1h | grep -c 'context_length_exceeded'

# Check HPA status and current replicas
kubectl -n dojo-rag get hpa rag-api -o wide
kubectl -n dojo-rag describe hpa rag-api | grep -A5 'Conditions:'
```

> **War story.** At SAP, a log-analysis feature that ran fine in staging had a $12,000 projected monthly cost in production's load test — an order of magnitude over budget. The culprit wasn't the LLM call itself; it was the context assembly step that was including the *full raw log line* (up to 8KB each) instead of extracting the structured fields first. The structured fields for the same log were ~120 tokens; the raw line was ~600. At 100,000 requests/day that was an 80% cost reduction hiding in a single pre-processing step: `log_context = extract_structured_fields(raw_log)` instead of `log_context = raw_log`. The fix took 20 minutes. The lesson: always measure `input_tokens` in production before you have a finance conversation. Token counts are your primary cost signal — instrument them like you'd instrument query latency.

---

## Checkpoint

You're ready for the serving and cost challenges when you can, without looking anything up:

1. Write the formula for estimated monthly LLM API cost given per-request input/output tokens and daily request volume. Compute it for two model tiers.
2. Implement a streaming SSE endpoint in FastAPI. Name the one Nginx annotation that makes streaming work through an ingress.
3. Explain the difference between exact and semantic caching. Give a real example where each fires (and doesn't).
4. Write a Redis-backed exact cache for LLM calls. What goes in the cache key?
5. Describe how Anthropic prompt caching works and when to enable it. Give a concrete cost comparison.
6. Draw the Kubernetes stack for a RAG API: which components are Deployments, which are Services, what does the HPA key off.
7. Diagnose a p99 latency spike: which three metrics do you check first and what command surfaces each?
8. What does `OLLAMA_NUM_PARALLEL` do and when would you increase it beyond the default?
9. Explain why a `/health` endpoint that always returns 200 is worse than no health endpoint at all.

➡ You've completed the module sequence. Head to the challenges to put these concepts to work — the first builds and evals a real RAG pipeline, the second instruments it for cost, and the bridge challenge deploys it to the kind cluster.
