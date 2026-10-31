# Embeddings Search

You're reviewing the retrieval layer of a RAG pipeline. The embeddings were generated offline and stored — the question is whether the similarity function is correct. The senior engineer left a comment: *"we had a bug where all similarity scores came out equal because someone used dot product instead of cosine similarity and forgot to normalise. The top-k order was garbage for any query that wasn't a unit vector. Write it properly."*

## What embeddings actually are

An embedding maps a piece of text to a dense float vector such that **semantically similar texts land near each other** in that vector space. "Near" is measured by cosine similarity — the angle between two vectors, not their length. Cosine similarity ignores magnitude, which is why it works well when vectors have different L2 norms (which precomputed embeddings almost always do).

```
cosine_similarity(a, b) = (a · b) / (‖a‖ · ‖b‖)
```

Range: `[-1, 1]`. `1.0` = identical direction. `0` = orthogonal (unrelated). `-1` = opposite.

Top-k retrieval: compute cosine similarity between a **query embedding** and every **corpus embedding**, then return the indices of the k highest-scoring documents.

## Mission

Implement two functions in `solution.py`:

```python
def cosine_similarity(a: list[float], b: list[float]) -> float:
    ...

def search(query_embedding: list[float],
           corpus_embeddings: list[list[float]],
           k: int) -> list[int]:
    ...
```

`search` returns a list of `k` indices into `corpus_embeddings`, ordered highest-similarity first.

The harness loads a 5-document corpus with precomputed 6-dimensional embeddings and runs four queries against your implementation. Each query has an unambiguous correct top-1 result. All four must be correct, plus a `k=2` test that checks the top-2 order.

## Target state

The verifier runs `pytest test_solution.py -v`. All tests must be green.

The corpus and its embeddings are in `corpus.json` and `embeddings.json` in your work dir. You do not need an LLM or the `numpy` library — the only import you need is `math`.

## Why cosine, not dot product

Dot product rewards long vectors. In practice, a document with 1000 tokens gets a longer embedding than a 20-token snippet, so dot product retrieval is biased toward long documents regardless of semantic relevance. Cosine similarity cancels magnitude — it cares only about direction. This is the *de facto* standard for dense retrieval, and it's the reason every serious vector database (pgvector, Pinecone, Chroma) defaults to cosine or inner-product on normalised vectors.
