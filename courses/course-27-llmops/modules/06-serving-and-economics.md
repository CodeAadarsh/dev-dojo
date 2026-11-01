# Serving & Cost Economics

> **Module 06 · Course 27** — A model that answers correctly but takes 8 seconds to respond and costs $4/request is not production-ready — it is a demo. This module covers the full stack between "an LLM API call works" and "LLM inference is fast, cheap, and reliable at production traffic."

The numbers in this module are real orders of magnitude. Your architecture decisions will be driven by them.

---

## Latency Budgets & Streaming

### Where the time goes

A typical LLM API request has three distinct latency components:

```
Client                      LLM Provider
  │──── HTTP + TLS ────────► │
  │                          │  [TTFT: time-to-first-token]
  │                          │  prompt processing (prefill)
  │◄────── first token ───── │
  │◄──── token 2 ──────────  │  [streaming: each token arrives as it's generated]
  │◄──── token 3 ──────────  │
  │◄──── ... ──────────────  │
  │◄──── last token ───────  │  [E2E: total wall clock]
```

| Metric | Typical range | Why it matters |
|--------|---------------|----------------|
| **TTFT** (time to first token) | 200 ms – 2 s | Perceived responsiveness; user sees "thinking" cursor |
| **Tokens/sec (decode speed)** | 20 – 150 tok/s | Output throughput; governs how long a long answer takes |
| **E2E latency** | 1 – 30 s | Total wait; dominant at high output token counts |
| **Network RTT** | 10 – 100 ms | Usually negligible vs inference; matters in multi-hop agent chains |

### Streaming

Always stream for user-facing features. Non-streaming requests block the HTTP connection until the full response is ready, turning a 10-second generation into a 10-second blank screen.

```python
# OpenAI-compatible streaming
import anthropic

client = anthropic.Anthropic()

with client.messages.stream(
    model="claude-3-haiku-20240307",
    max_tokens=512,
    messages=[{"role": "user", "content": prompt}]
) as stream:
    for text in stream.text_stream:
        print(text, end="", flush=True)          # forward each chunk to your client
```

For backend-to-backend calls in an agent chain where the downstream consumer processes the full result anyway, non-streaming is fine — streaming adds per-chunk overhead with no latency benefit.

### Latency Budget Allocation

In an agentic chain with N steps, latency compounds:

```
E2E ≈ N × (TTFT + output_tokens / decode_speed) + Σ(tool_execution_times)
```

For a 10-step agent at 500 ms TTFT, 50 tok/s, 100 output tokens/step:
```
E2E ≈ 10 × (0.5 + 100/50) + tool_time = 10 × 2.5 + tool_time = 25 s + tool_time
```

This is why agent latency budgets force you toward small models (faster decode) + short-circuit on early answers + parallel tool execution.

---

## Caching

Caching is the highest-leverage cost and latency reduction available. Two kinds:

### Exact (Lexical) Cache

Hash the full request (model + messages + params) and store the response. A cache hit costs a hash comparison and a Redis round-trip; no token billing.

```python
import hashlib, json, redis

cache = redis.Redis()

def llm_with_cache(payload: dict) -> dict:
    key = "llm:" + hashlib.sha256(
        json.dumps(payload, sort_keys=True).encode()
    ).hexdigest()
    cached = cache.get(key)
    if cached:
        return json.loads(cached)
    response = call_llm_api(payload)
    cache.setex(key, 3600, json.dumps(response))   # 1-hour TTL
    return response
```

Exact caching is effective for repeated identical prompts — template-based prompts with a fixed system prompt and a small set of user messages. Hit rates of 40–80% are achievable for FAQ-style workloads. Hit rate drops toward zero for open-ended conversational agents.

### Semantic (Embedding) Cache

Hash is useless when prompts are semantically equivalent but textually different ("what's the capital of France?" vs "tell me the capital city of France"). Semantic caching:

1. Embed the incoming prompt.
2. Query a vector store for the nearest cached prompt.
3. If cosine similarity > threshold (typically 0.95), return the cached response.
4. Otherwise call the LLM and store `(embedding, prompt, response)`.

```python
from numpy import dot
from numpy.linalg import norm

def cosine_sim(a, b):
    return dot(a, b) / (norm(a) * norm(b))

def semantic_cache_lookup(query_embedding, threshold=0.95):
    hits = vector_store.query(query_embedding, top_k=1)
    if hits and cosine_sim(query_embedding, hits[0]["vector"]) >= threshold:
        return hits[0]["cached_response"]
    return None
```

Semantic caching requires an embedding call per request (cheap: ~$0.0001 per query with most providers, or free with a local model). The break-even is one LLM call saved per ~10–50 embedding calls, which is usually met quickly for production workloads.

#### Cache invalidation

The classic hard problem applies here too:

- **Stale factual answers.** A cached answer to "what is the current price of X" was correct yesterday. TTL is the primary control; shorter for time-sensitive data.
- **Prompt template changes.** If you change the system prompt, all cached responses generated under the old prompt are stale. Include a prompt version hash in the cache key.
- **Model version changes.** Response quality and format differ across model versions. Namespace cache keys by `model_id` + `model_version`.

---

## Request Batching

GPU inference is embarrassingly parallelizable across the batch dimension. A GPU serving a batch of 8 requests takes roughly the same wall-clock time as a batch of 1 — so throughput scales with batch size at almost no latency cost, up to the GPU's VRAM ceiling.

Most hosted APIs do continuous batching invisibly. You pay for throughput, not batch size. But in self-hosted deployments (vLLM, TGI, Ollama), batching is your responsibility.

```
Without batching:          With batching (batch=4):
req1 → GPU → resp1         [req1, req2, req3, req4] → GPU → [resp1, resp2, resp3, resp4]
req2 → GPU → resp2         Total wall clock ≈ single-request time
req3 → GPU → resp3
req4 → GPU → resp4
Total wall clock ≈ 4× single-request time
```

For asynchronous workloads (batch eval, nightly report generation, grading pipelines), collect requests into a queue and flush at a target batch size or interval:

```python
import asyncio
from collections import deque

BATCH_SIZE = 16
FLUSH_INTERVAL_S = 0.1   # 100 ms max wait before flushing a partial batch

queue: deque = deque()

async def flush_batch():
    while True:
        await asyncio.sleep(FLUSH_INTERVAL_S)
        if not queue:
            continue
        batch = []
        while queue and len(batch) < BATCH_SIZE:
            batch.append(queue.popleft())
        responses = await llm_batch(batch)
        for req, resp in zip(batch, responses):
            req["future"].set_result(resp)
```

For user-facing features, batching introduces latency (you wait for the batch to fill). Acceptable for background pipelines; unacceptable for interactive chat.

---

## Model Routing & Fallback

Not every query needs GPT-4/claude-3-opus. The routing question is: **given this specific request, what is the cheapest model that will produce an acceptable answer?**

### Capability Tiers

| Tier | Examples | Token cost ratio | Use for |
|------|----------|-------------------|---------|
| **Small / fast** | Haiku, Gemini Flash, GPT-4o-mini | 1× | Classification, extraction, short Q&A, tool call parsing |
| **Mid** | Sonnet, GPT-4o, Mistral-medium | 5–10× | Multi-step reasoning, code generation, drafting |
| **Large / smart** | Opus, GPT-4, Gemini Ultra | 15–30× | Complex novel reasoning, adversarial prompts, final review |

### Routing Strategies

**Heuristic routing** — rules based on prompt properties:

```python
def route(prompt: str, tools: list) -> str:
    if len(prompt) < 200 and not tools:
        return "claude-3-haiku-20240307"
    if len(tools) > 3 or "code" in prompt.lower():
        return "claude-sonnet-4-5"
    return "claude-sonnet-4-5"
```

**Classifier routing** — a cheap model decides which expensive model to use:

```python
routing_prompt = f"""Classify the complexity of this user request:
- simple: factual lookup, short answer, no reasoning chain needed
- complex: multi-step reasoning, code generation, judgment calls

Request: {user_prompt}
Reply with exactly one word."""

classification = cheap_model.complete(routing_prompt).content.strip()
model = "haiku" if classification == "simple" else "sonnet"
```

The classifier model itself costs ~$0.001/request — it breaks even if it routes even 1% of traffic away from the expensive model.

**Cascading fallback:**

```python
models_in_order = [
    ("claude-3-haiku-20240307", 0.8),    # model, quality threshold
    ("claude-sonnet-4-5",       0.9),
    ("claude-opus-4-5",         1.0),
]

for model_id, threshold in models_in_order:
    response = llm(prompt, model=model_id)
    score = quality_check(response)    # heuristic or LLM-as-judge
    if score >= threshold:
        return response

return response   # best we got from the most capable model
```

Cascading works for offline pipelines where you can afford two calls on hard prompts. For latency-sensitive paths, route upfront — don't cascade.

---

## Token Accounting & Budgets

Token cost is not uniform across the request:

```
Input tokens  × input_price   +   output tokens  × output_price   =   request cost

Example (claude-3-haiku as of late 2025):
  2,000 input  × $0.25/MTok   +   500 output × $1.25/MTok
= $0.000500   +   $0.000625
= $0.001125 per request
```

At 100 req/s that is $4,050/month — for one of the cheapest models. Knowing where tokens go is the first step to reducing spend.

### What burns tokens (ordered by surprise)

1. **System prompts** — charged on every single request, even if the system prompt never changes. A 2,000-token system prompt at 1M req/month = 2B tokens / month in system prompt alone. Use prompt caching if your provider supports it (Anthropic charges reduced rates for cached prompt prefixes).
2. **Retrieved context (RAG)** — injecting 5 retrieved chunks × 500 tokens = 2,500 tokens per query. Truncate aggressively; use smaller chunks with reranking.
3. **Multi-turn history** — the full conversation is re-sent on every turn. A 20-turn conversation at 200 tokens/turn = 4,000 tokens of history injected by turn 20. Summarize old turns.
4. **Agent tool results** — raw tool output injected as-is. Summarize before appending.
5. **Output verbosity** — the model will happily write 500 words when 50 suffice. Constrain via system prompt ("respond in at most 3 sentences") and `max_tokens`.

---

## Local (Ollama) vs API Tradeoffs

Running a model locally on an M2 Mac Mini with Ollama is free at marginal cost but has real constraints:

| Dimension | Ollama (local) | Cloud API |
|-----------|---------------|-----------|
| **Cost** | 0 marginal (hardware already owned) | $0.001–$0.03/1K tokens |
| **Privacy** | Prompts never leave your machine | Subject to provider ToS; some log by default |
| **Latency** | 5–15 tok/s on M2 8 GB (quantized 7B) | 30–100 tok/s (varies by provider/load) |
| **Max context** | 4–8K tokens for 7B on 8 GB | 100K–1M tokens on frontier models |
| **Model quality** | 7B–13B quantized; good for structured tasks, weak on complex reasoning | Frontier quality |
| **Availability** | Your hardware uptime | 99.9%+ SLA |
| **Scaling** | Capped at one machine | Horizontal by default |

**Rule of thumb for SAP AI Core context:** use local Ollama for dev/test where quality is flexible (prompt iteration, unit test mocks, low-stakes classification). Use API models for anything user-facing, evaluation, or production. The privacy argument is real for anything touching customer data — check the data classification policy before sending a prompt to any external API.

---

## Quantization & Distillation

When running self-hosted models, two techniques reduce the cost per token:

### Quantization

Reduces weight precision from FP16/BF16 to INT8 or INT4. A 13B model at FP16 needs ~26 GB VRAM; the same model at Q4_K_M (4-bit) fits in ~7 GB.

```
FP16 (full precision)  → best quality, highest VRAM and memory bandwidth
INT8 (8-bit quant)     → ~1–2% quality drop, 2× memory savings
Q4_K_M (4-bit)         → ~3–5% quality drop on benchmarks, 4× savings; fits on consumer hardware
```

The quality tradeoff is task-dependent. Q4 models are nearly indistinguishable from FP16 on structured tasks (JSON extraction, classification, code completion with a clear spec). Complex multi-step reasoning shows larger degradation — test your specific task before choosing.

### Knowledge Distillation

Train a smaller "student" model to imitate a larger "teacher" model on your specific task distribution. If 95% of your traffic is "classify this support ticket into one of 12 categories," a distilled 1B model fine-tuned on teacher-generated labels will outperform a generic 7B model at 7× lower inference cost.

Distillation is a significant investment (you need a representative dataset, fine-tuning infrastructure, evaluation). Worth pursuing when: traffic volume is high, the task is narrow and well-defined, and you've confirmed that quality is acceptable at smaller scale.

---

## Debugging Serving & Cost Problems

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| p99 latency spikes despite low average | Output token count variance is high; a few long-form responses skew the tail | Add `max_tokens` per request type; monitor output token distributions, not just averages |
| Daily cost 3× expected despite expected traffic | System prompt too long (charged per request); multi-turn history accumulating; no output length cap | Audit tokens per request component; implement prompt caching; summarize history; set `max_tokens` |
| Semantic cache hit rate < 5% despite repeated queries | Threshold too high (0.95 is strict); embedding model differs between cache-write and cache-read time; queries are genuinely diverse | Lower threshold to 0.90 and re-measure; pin embedding model version; verify both calls use the same model |
| `context_length_exceeded` for long conversations | Multi-turn history sent verbatim; no summarization | Sliding window: keep last N turns + rolling summary of earlier; or switch to a model with a larger context window as a stopgap |
| Model routing sends too many requests to the expensive tier | Classifier is biased toward "complex" or heuristics are loose | Audit classification outputs on a sample; retrain or tighten heuristics; add a cost-per-request metric by tier |
| Local Ollama decode rate < 3 tok/s | Model does not fit in VRAM; weights are memory-bandwidth-bound, not compute-bound | Use a more aggressively quantized variant (Q4 instead of Q8); reduce context window size; or switch to a smaller model |

> **War story.** On a cost audit at SAP, a team's LLM feature had ballooned to $2,800/month with seemingly modest traffic. The breakdown: system prompt was 4,200 tokens, re-sent verbatim on every request; there was no `max_tokens` set, so the model was generating 1,200–3,000 tokens per response on questions that warranted 100. No prompt caching was configured. Three changes — truncate the system prompt to 900 tokens, set `max_tokens=400`, enable prompt caching — dropped the bill to $420/month without any detectable quality change. Token cost is not an ops problem, it is a product engineering problem. The team that writes the prompt owns the bill.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Name the three latency components of an LLM request (TTFT, decode speed, E2E) and explain which one dominates for a 500-token output.
2. Write the formula for agent chain E2E latency as a function of N steps, TTFT, decode speed, and output tokens per step.
3. Explain the difference between exact and semantic caching, and give one scenario where exact caching achieves a 60%+ hit rate and one where it achieves nearly 0%.
4. Name two cache invalidation scenarios specific to LLMs that do not occur in a typical HTTP response cache.
5. Describe cascading fallback and explain why it is unsuitable for latency-sensitive user-facing paths.
6. List the four token categories (system prompt, RAG context, multi-turn history, output) and rank them by "surprising cost at scale."
7. State the rule of thumb for when to use local Ollama vs a cloud API, given a data-classification constraint.
8. Explain the p99 spike root cause and what metric you must monitor alongside average latency to detect it early.

➡ Next up: **Observability for LLMs** — if you cannot see what a model did, you cannot know when it quietly got worse.
