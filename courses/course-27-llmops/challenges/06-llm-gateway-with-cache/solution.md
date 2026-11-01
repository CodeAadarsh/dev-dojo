# Solution — LLM Gateway with Cache

## The complete `LLMGateway.complete()` implementation

```python
def complete(self, prompt: str) -> str:
    # Stage 1 — exact cache
    if prompt in self._exact:
        return self._exact[prompt]

    # Stage 2 — semantic cache
    new_emb = embed(prompt)
    for cached_emb, cached_response in self._semantic:
        if cosine_similarity(new_emb, cached_emb) >= self.threshold:
            return cached_response

    # Stage 3 — model call with fallback
    try:
        response = self.primary.complete(prompt)
    except Exception:
        response = self.fallback.complete(prompt)

    # Store in both caches before returning
    self._exact[prompt] = response
    self._semantic.append((new_emb, response))

    return response
```

## Why each stage is in this order

**Exact cache first.** O(1) dict lookup is the cheapest possible check. If the prompt was seen before verbatim, return immediately. No embedding computation, no model call.

**Semantic cache second.** `embed()` is O(|VOCAB|) = O(13) — negligible. The scan over `self._semantic` is O(N·|VOCAB|) where N is the number of distinct prompts seen. For typical gateway volumes this is fast enough; production systems use a vector database (FAISS, pgvector) for sub-linear ANN search when N exceeds tens of thousands.

**Model call last.** Compute the embedding *before* the model call (`new_emb = embed(prompt)`) so it's ready to store without recomputing.

**`except Exception` (not `except RuntimeError`).** A gateway must catch everything the primary can throw — `RuntimeError`, `TimeoutError`, `ConnectionError`, an HTTP 429, etc. Narrowing the except clause means a novel error type bypasses the fallback. The fallback contract is: "if the primary fails for any reason, try the fallback."

## Semantic cache math

`embed("capital of france")` → `[0,0,0,1,1,1,0,0,0,0,0,0,0]` (capital, of, france at indices 3–5)
`embed("france capital")`    → `[0,0,0,1,0,1,0,0,0,0,0,0,0]` (capital, france)

```
dot  = 1·1 + 1·0 + 1·1         = 2
|a|  = √(1+1+1)                 = √3 ≈ 1.732
|b|  = √(1+1)                   = √2 ≈ 1.414
cos  = 2 / (1.732 × 1.414)     ≈ 0.816
```

`0.816 >= 0.75 (SIMILARITY_THRESHOLD)` → semantic cache hit. The test `test_semantic_cache_hits_on_similar_prompt` verifies this assumption before checking the gateway behaviour, so a modified `embed()` or threshold fails with a clear message.

For `"capital of france"` vs `"what is 2+2"`: the only shared vocabulary words are none (2+2 is not in VOCAB). Cosine = 0 < 0.75 → cache miss → second model call. This is the `test_semantic_cache_misses_on_dissimilar_prompt` test.

## Fallback and caching interaction

When `primary.should_fail = True`:
- Stage 1: `_exact` is empty → miss
- Stage 2: `_semantic` is empty → miss
- Stage 3: `primary.complete()` raises (increments `call_count` to 1), fallback called (increments to 1), response stored in both caches

Second identical call:
- Stage 1: `_exact[prompt]` exists → return immediately
- `fallback.call_count` stays at 1 ✓

This is why `test_fallback_response_cached` passes: the gateway doesn't distinguish "this came from the fallback" vs "this came from the primary" — the cached value is just a response string.

## Optional extension — deploy as a FastAPI service to kind

```python
# app.py — thin FastAPI wrapper around LLMGateway
from fastapi import FastAPI
from pydantic import BaseModel
from gateway import LLMGateway, MockLLM

app = FastAPI()
_gw = LLMGateway(MockLLM("primary"), MockLLM("fallback"))

class PromptRequest(BaseModel):
    prompt: str

@app.post("/complete")
def complete(req: PromptRequest):
    return {"response": _gw.complete(req.prompt), "cached": req.prompt in _gw._exact}
```

Build, load, and deploy to a dojo namespace:

```bash
docker build -t llm-gateway:dev .
kind load docker-image llm-gateway:dev --name dojo
kubectl create namespace dojo-llm-gateway --dry-run=client -o yaml | kubectl apply -f -
kubectl -n dojo-llm-gateway create deploy gateway --image=llm-gateway:dev \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n dojo-llm-gateway rollout status deploy/gateway
```

The cache state is in-process (per-replica, non-shared). Production caches use Redis or a sidecar to share state across replicas.

## Apply and verify

```bash
cd ~/.kube-dojo-work/06-llm-gateway-with-cache
# replace complete() with the solution above, then:
.venv/bin/pytest tests/ -v
bash courses/course-27-llmops/challenges/06-llm-gateway-with-cache/verify.sh
```
