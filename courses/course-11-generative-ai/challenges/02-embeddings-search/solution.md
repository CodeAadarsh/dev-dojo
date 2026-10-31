# Solution — Embeddings Search

Both functions fit in ~15 lines of standard Python.

```python
# solution.py
import math

def cosine_similarity(a: list, b: list) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(y * y for y in b))
    if norm_a == 0.0 or norm_b == 0.0:
        raise ValueError("cosine similarity is undefined for the zero vector")
    return dot / (norm_a * norm_b)


def search(query_embedding: list, corpus_embeddings: list, k: int) -> list:
    scores = [
        (cosine_similarity(query_embedding, doc_emb), idx)
        for idx, doc_emb in enumerate(corpus_embeddings)
    ]
    scores.sort(key=lambda x: x[0], reverse=True)
    return [idx for _, idx in scores[:k]]
```

## Why each line matters

**`dot = sum(x * y for x, y in zip(a, b))`** — dot product: the numerator of cosine similarity. `zip` stops at the shorter vector, so this silently ignores extra dimensions if vectors are mismatched. A production implementation would assert `len(a) == len(b)`.

**`norm_a = math.sqrt(sum(x * x for x in a))`** — L2 norm (Euclidean length). Dividing by both norms "projects" the dot product onto the unit sphere; the result is the cosine of the angle between the vectors.

**`scores.sort(..., reverse=True)`** — `sort` is stable and O(n log n). For very large corpora (millions of vectors), you'd use `numpy` with batched matrix multiplication (`corpus_embeddings @ query_embedding`) and `np.argsort`; for a few hundred documents, pure Python is fine.

**`[:k]` after sorting** — takes the top k. An alternative for large k-values is `heapq.nlargest(k, scores)`, which is O(n log k) instead of O(n log n), but the difference is negligible at this scale.

## The dot-product trap

Consider two documents:
- Doc A: 500-word article on caching → embedding magnitude ≈ 50
- Doc B: 10-word definition of caching → embedding magnitude ≈ 5

Their semantic similarity (angle) is nearly identical. Dot product with a caching query:
- `dot(q, A)` ≈ 10× larger than `dot(q, B)` purely due to magnitude

Cosine similarity: both score ~0.95. Dot product: A always beats B by 10×. If you're building a snippet retrieval system, dot product buries all your short, precise answers under long documents.

## Scaling up

In production you wouldn't implement this from scratch:
- `pgvector` adds `<=>` (cosine distance) and `<#>` (inner product) operators to Postgres — you already run Postgres.
- `numpy` + batched matrix multiply is ~100× faster than pure Python for >10k documents.
- Libraries like `sentence-transformers` handle both embedding and retrieval.

The manual implementation here makes the math explicit — the same math every vector store uses under the hood.
