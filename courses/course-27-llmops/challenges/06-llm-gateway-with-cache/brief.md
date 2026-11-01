# LLM Gateway with Cache

The cost dashboard for your team's chatbot shows the same thirty prompts accounting for 60% of model spend — users rephrasing the same questions slightly differently. You get two tickets in the same sprint: *"Add a cache"* and *"Add a fallback for when the primary model is rate-limited."*

These are almost always the same ticket in disguise. Your job: implement `LLMGateway.complete()`.

## Context

`setup.sh` plants a work directory:

```
~/.kube-dojo-work/06-llm-gateway-with-cache/
├── gateway.py          # MockLLM, embed(), cosine_similarity() provided
│                       # implement LLMGateway.complete() only
└── tests/
    └── test_gateway.py # seven-test harness; all must pass
```

No cluster, no network. The model is a mock that counts calls.

## Prerequisites

```bash
cd ~/.kube-dojo-work/06-llm-gateway-with-cache
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement `LLMGateway.complete(prompt)` with this three-stage strategy:

1. **Exact cache** (`self._exact: dict`): if `prompt` is already a key, return the stored response immediately.
2. **Semantic cache** (`self._semantic: list` of `(embedding, response)` tuples): compute `embed(prompt)`, scan for any entry where `cosine_similarity(new_emb, cached_emb) >= self.threshold`. Return the first match.
3. **Model call**: try `self.primary.complete(prompt)`; on any exception, call `self.fallback.complete(prompt)`. Store the result in both caches before returning.

The provided `embed()` uses a fixed vocabulary bag-of-words; `cosine_similarity()` computes standard cosine distance. Both are deterministic. The default `SIMILARITY_THRESHOLD = 0.75`.

The exact conditions `verify.sh` checks:

| Test | What it asserts |
|------|-----------------|
| `test_exact_cache_on_repeated_prompt` | Two identical prompts → 1 model call |
| `test_exact_cache_three_repetitions` | Four identical prompts → 1 model call |
| `test_semantic_cache_hits_on_similar_prompt` | "capital of france" then "france capital" → 1 model call |
| `test_semantic_cache_misses_on_dissimilar_prompt` | "capital of france" then "what is 2+2" → 2 model calls |
| `test_fallback_on_primary_failure` | Primary raises → fallback called, result returned |
| `test_fallback_response_cached` | After fallback, second identical prompt → 0 additional model/fallback calls |
| `test_primary_used_when_healthy` | Healthy primary → fallback call count = 0 |

## Why this architecture matters

A model gateway is the single choke-point where you can implement cross-cutting concerns without touching every caller:

```
caller A ─┐
caller B ─┤─► LLMGateway ──► exact cache ──► semantic cache ──► primary model
caller C ─┘                                                  └──► fallback model
```

**Exact cache** handles word-for-word repeats — FAQ bots, template-driven prompts. O(1) dict lookup, zero overhead on misses.

**Semantic cache** handles near-duplicates — users asking the same thing with different phrasing. The embedding used here is a toy (bag-of-words over a 13-word vocabulary); production systems use a real sentence encoder (e.g. a lightweight bi-encoder or a dedicated embedding API). The structure of the logic is identical.

**Fallback** keeps the service available through partial outages. The fallback can be a cheaper model, a different provider, or a cached static response. What matters is that the decision is made *at the gateway*, not scattered across every caller.

> **War story.** At SAP, we had an LLM-backed log summariser. It worked perfectly until the primary endpoint hit a quota reset at midnight UTC and all pending requests 500'd simultaneously. Callers had no retry logic; the on-call engineer woke up to 2,000 alerts. The fix took three hours to deploy. A gateway with a fallback and an exact cache (for the 90% of requests that were identical alert summaries) would have served the midnight traffic from cache and fallen back gracefully for the novel ones. The gateway now exists; the midnight alert does not.

## Verify

```bash
bash courses/course-27-llmops/challenges/06-llm-gateway-with-cache/verify.sh
```

All seven tests green → flag printed.
