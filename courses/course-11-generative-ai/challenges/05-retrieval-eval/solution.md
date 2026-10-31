# Solution — Retrieval Evaluation

## The complete `retriever.py`

```python
import numpy as np


def retrieve(query_emb: list, corpus_embs: list, k: int) -> list:
    q = np.array(query_emb, dtype=float)
    C = np.array(corpus_embs, dtype=float)

    # Cosine similarity: (q · cᵢ) / (‖q‖ · ‖cᵢ‖)
    dot_products = C.dot(q)
    norms = np.linalg.norm(C, axis=1) * np.linalg.norm(q)
    # Guard against zero-norm vectors (none in this dataset, but robust code handles it)
    norms = np.where(norms == 0, 1e-10, norms)
    similarities = dot_products / norms

    # argsort is ascending; flip for descending, take first k
    top_k = np.argsort(similarities)[::-1][:k].tolist()
    return top_k
```

## Why the stub fails (recall@3 = 0.0)

The stub returns `list(range(k))` = `[0, 1, 2]`. The five labeled queries have relevant documents at indices `[6, 4, 7, 1, 5]`. None of those indices appear in `[0, 1, 2]`, so every query is a miss and recall@3 = 0/5 = 0.0.

## Why dot product alone would also fail on this dataset

The corpus embeddings are deliberately designed with inflated magnitudes on docs 1, 3, 5, 7 (magnitude ≈ 50) versus docs 0, 2, 4, 6 (magnitude ≈ 10). For a query with a small cross-dimensional component, raw dot product assigns a high score to the large-magnitude docs regardless of actual semantic alignment.

Example for query 0 (caching/Redis, points strongly at dim 6):
```
query_emb = [0, 0, 0, 0, 0, 0, 9, 1]
doc 6 (Redis):    emb = [0, 0, 0, 0, 0, 0, 10, 0.5]  →  dot = 90.5,  ‖doc6‖ ≈ 10.01
doc 7 (Security): emb = [0, 0, 0, 0, 0, 0, 0.5, 50]  →  dot = 4.5+50 = 54.5, ‖doc7‖ ≈ 50.0
```
Dot product: doc 7 (54.5) beats doc 6 (90.5)? No, doc 6 wins by dot product here too.

But for query 3 (K8s, points strongly at dim 1):
```
query_emb = [1, 9, 0, 0, 0, 0, 0, 0]
doc 1 (K8s):    emb = [0.5, 50, 0, 0, 0, 0, 0, 0]  →  dot = 0.5 + 450 = 450.5
doc 0 (Python): emb = [10, 0.5, 0, 0, 0, 0, 0, 0]   →  dot = 10 + 4.5 = 14.5
```
Both dot product and cosine pick doc 1 here. The magnitude inflation matters most when there's cross-dimensional leakage. In production datasets with real embeddings this failure mode is much more pronounced — it's why every serious vector database defaults to normalised inner product (= cosine).

## Understanding recall@k in production

A recall@3 of 0.80 means 4 out of 5 queries found their relevant document in the top 3. In a real RAG system with a 3-chunk context window, an 80% recall means 1 in 5 answers has no ground-truth information available to the model — it will either hallucinate or say "I don't know."

Improving recall@k in practice:
- **Better embeddings** — a fine-tuned bi-encoder (BGE, E5) vs. a generic model
- **Re-ranking** — cross-encoder re-ranks the top-20 candidates; cheap retrieval narrows the pool, expensive re-ranker gets the order right
- **Hybrid search** — combine dense retrieval scores with BM25 (keyword) scores; works well when queries contain rare technical terms the embedding model may not have seen often
- **Chunking strategy** — overlapping chunks, sentence-level splitting, or hierarchical (summary → chunk) can put more relevant signal in a single chunk

## Apply and verify

```bash
cd ~/.kube-dojo-work/05-retrieval-eval
python eval_harness.py    # recall@1, @3, @5 should now be 1.00
bash courses/course-11-generative-ai/challenges/05-retrieval-eval/verify.sh
```
