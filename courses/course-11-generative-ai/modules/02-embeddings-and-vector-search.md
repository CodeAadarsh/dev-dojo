# Embeddings & Vector Search

> **Module 02 · Course 11** — Text is discrete; meaning is continuous. An embedding model maps text into a point in high-dimensional space such that semantically similar texts land near each other. Once you understand that geometry, vector search is just "find the nearest points," and every failure mode — wrong results, slow queries, index drift — becomes a geometry problem you can reason about.

You have used keyword search before. The goal here is to understand what vector search can do that keyword search cannot, where it breaks, and how to wire a production-quality chunk-to-vector pipeline from scratch.

Install the working dependencies:

```bash
pip install ollama httpx numpy chromadb faiss-cpu sentence-transformers
ollama pull nomic-embed-text   # 768-dim, 274 MB — fast on Mac Mini M2
```

> **API-key alternative.** All embedding calls use Ollama's `nomic-embed-text` locally. To swap to OpenAI: `from openai import OpenAI; client = OpenAI()` then `client.embeddings.create(model="text-embedding-3-small", input=[...])` — the response shape is slightly different but the vector is in `.data[0].embedding`. Dimensions differ (nomic=768, ada-002=1536, 3-small=1536, 3-large=3072); re-index everything if you switch models.

---

## What an embedding is

An embedding model is a neural network trained (typically via contrastive learning) to map text to a fixed-length vector such that semantically similar text produces similar vectors. "Similar" here means "placed near each other in the embedding space."

```
"pod crashed with OOMKilled"    →  [0.12, -0.45, 0.78, ... ] (768 numbers)
"container hit memory limit"    →  [0.13, -0.43, 0.76, ... ] (nearby)
"kubectl get nodes"             →  [-0.88, 0.11, -0.33, ... ] (far away)
```

The actual numbers are opaque — they are learned weights, not human-interpretable dimensions. What is interpretable is the **geometry**: nearby vectors represent similar meaning.

```python
import ollama

client = ollama.Client()

def embed(text: str) -> list[float]:
    return client.embeddings(model="nomic-embed-text", prompt=text).embedding

# Batch via the REST API (more efficient for large corpora)
import httpx

def embed_batch(texts: list[str]) -> list[list[float]]:
    resp = httpx.post(
        "http://localhost:11434/api/embed",
        json={"model": "nomic-embed-text", "input": texts},
        timeout=60.0,
    )
    resp.raise_for_status()
    return resp.json()["embeddings"]   # list[list[float]]

# Quick sanity check — similar texts should score > 0.8
import numpy as np

def cosine(a: list[float], b: list[float]) -> float:
    a, b = np.array(a, dtype=np.float32), np.array(b, dtype=np.float32)
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))

v1 = embed("pod crashed with OOMKilled")
v2 = embed("container hit memory limit")
v3 = embed("kubectl get nodes")

print(cosine(v1, v2))   # expect ~0.88
print(cosine(v1, v3))   # expect ~0.55
```

---

## Distance metrics

Three metrics are in common use. Pick the wrong one and your similarity scores are meaningless numbers.

### Cosine similarity

Measures the **angle** between two vectors, ignoring magnitude. It is the correct metric for text embeddings because the same document at different lengths or frequencies of repetition should have the same semantic direction.

```
cosine(a, b) = dot(a, b) / (||a|| × ||b||)
```

Range: −1 (opposite) to +1 (identical). For text embeddings in practice: > 0.85 is very similar, < 0.60 is unrelated.

```python
import numpy as np

def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))
```

### Dot product (inner product)

When vectors are **L2-normalized** (unit length), dot product equals cosine similarity — they are identical operations. Most FAISS indices and many vector databases operate on dot product internally for speed; they assume you have normalized first.

```python
def dot_product(a: np.ndarray, b: np.ndarray) -> float:
    # Only meaningful for similarity if both a and b are unit vectors
    return float(np.dot(a, b))

def normalize(v: np.ndarray) -> np.ndarray:
    return v / np.linalg.norm(v)
```

> **This is the single most common production bug in vector search.** If half your index was added with normalized vectors and half without, dot-product similarity returns incorrect rankings that look plausible because the numbers are in a vaguely reasonable range. See Debugging below.

### L2 distance (Euclidean)

Measures straight-line distance between points. Use it when the **magnitude** of the embedding carries meaning — which is unusual for text but common in image embeddings and scientific data. Smaller = more similar (opposite sign convention from cosine).

```python
def l2_distance(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.linalg.norm(a - b))
```

| Metric | Use for text | Notes |
|--------|-------------|-------|
| Cosine | Yes — always normalize mentally | Correct for variable-length text |
| Dot product | Yes — **only if vectors are unit-length** | Faster; equals cosine when normalized |
| L2 | Rarely | Useful for images, scientific; magnitude must be meaningful |

---

## Dimensionality and model selection

The embedding dimensionality controls both model quality and infrastructure cost. More dimensions → finer-grained geometry → better retrieval, but also more memory, slower indexing, and slower similarity computation.

| Model | Dimensions | Max input | Notes |
|-------|-----------|-----------|-------|
| `nomic-embed-text` (local) | 768 | 8192 tokens | Good quality for retrieval; runs on Mac Mini |
| `all-MiniLM-L6-v2` (local) | 384 | 256 tokens | Tiny and fast; quality drops on long text |
| `text-embedding-3-small` (API) | 1536 | 8191 tokens | Strong general-purpose |
| `text-embedding-3-large` (API) | 3072 | 8191 tokens | Best quality; 2× the cost of 3-small |
| `text-embedding-ada-002` (API, legacy) | 1536 | 8191 tokens | Older; replaced by 3-small |

**Dimensionality math in practice:**

```python
# Memory footprint for 1M documents, float32 (4 bytes per float)
def index_size_mb(n_docs: int, dim: int) -> float:
    return n_docs * dim * 4 / 1024 / 1024

print(f"1M docs @ 768-dim:  {index_size_mb(1_000_000, 768):.0f} MB")   # ~3 GB
print(f"1M docs @ 1536-dim: {index_size_mb(1_000_000, 1536):.0f} MB")  # ~6 GB
print(f"1M docs @ 3072-dim: {index_size_mb(1_000_000, 3072):.0f} MB")  # ~12 GB
```

For the Mac Mini (8 GB RAM, shared with OS and running models): `nomic-embed-text` at 768 dimensions lets you hold a ~1M-document index in memory alongside a running llama3.2.

> **Never mix dimensions in the same index.** Switching embedding models mid-stream is a full re-index — there is no migration path. Pick a model, document it in your ingestion code, and re-embed everything when you upgrade.

---

## ANN: HNSW and IVF

Exact nearest-neighbor search scales as O(n × d) per query — linear in the number of vectors. At 1M+ documents that is too slow for real-time use. **Approximate Nearest Neighbor (ANN)** algorithms trade a small accuracy loss for orders-of-magnitude faster queries.

### HNSW (Hierarchical Navigable Small World)

Builds a multi-layer graph. Query traversal is O(log n). Used by: ChromaDB, pgvector, Weaviate, Qdrant.

```python
import faiss
import numpy as np

DIM = 768
M = 32          # graph connectivity — higher = better recall, more memory
EF_CONSTRUCTION = 200   # build quality — higher = slower build, better quality
EF_SEARCH = 100         # query quality — tune this at query time

index = faiss.IndexHNSWFlat(DIM, M)
index.hnsw.efConstruction = EF_CONSTRUCTION
index.hnsw.efSearch = EF_SEARCH

# Vectors MUST be float32 and (for cosine) unit-normalized before adding
vecs = np.random.rand(10_000, DIM).astype(np.float32)
faiss.normalize_L2(vecs)   # in-place L2 normalization → unit vectors
index.add(vecs)

query = np.random.rand(1, DIM).astype(np.float32)
faiss.normalize_L2(query)
scores, indices = index.search(query, k=5)
print(indices, scores)     # indices are row positions in the original array
```

HNSW properties: fast queries (sub-millisecond at 1M), no training step, high recall (> 0.95 typical), but index cannot be updated incrementally on disk — you rebuild after bulk additions.

### IVF (Inverted File)

Partitions vectors into Voronoi cells (clusters). A query searches only the nearest `nprobe` cells — trades recall for speed.

```python
nlist = 256    # number of Voronoi cells; rule of thumb: sqrt(n_docs) to 4×sqrt(n_docs)
quantizer = faiss.IndexFlatIP(DIM)    # IP = inner product (cosine after L2-normalize)
index_ivf = faiss.IndexIVFFlat(quantizer, DIM, nlist, faiss.METRIC_INNER_PRODUCT)

# IVF requires a training step on a representative sample
train_vecs = np.random.rand(50_000, DIM).astype(np.float32)
faiss.normalize_L2(train_vecs)
index_ivf.train(train_vecs)
index_ivf.add(train_vecs)
index_ivf.nprobe = 16    # search 16 of 256 cells — tune recall/latency tradeoff here
```

| Algorithm | Build | Query | Update | Best for |
|-----------|-------|-------|--------|----------|
| Exact (Flat) | O(1) | O(n×d) | O(1) | < 50k vectors |
| HNSW | O(n log n) | O(log n) | Expensive | General-purpose; low-latency |
| IVF | O(n) + train | O(nprobe×cell) | Batch | Large corpora; tunable recall/speed |

---

## Vector databases

You almost never use raw FAISS in production. The three tools worth knowing:

### Chroma — development and prototyping

```python
import chromadb

# Persistent local store — survives restarts
client = chromadb.PersistentClient(path=".chroma")

collection = client.get_or_create_collection(
    name="knowledge",
    metadata={"hnsw:space": "cosine"},   # specify metric at creation; cannot change later
)

# Add documents with pre-computed embeddings
collection.add(
    ids=["doc1", "doc2", "doc3"],
    documents=["text one", "text two", "text three"],
    embeddings=[[0.1] * 768, [0.2] * 768, [0.3] * 768],   # replace with real vectors
    metadatas=[{"source": "wiki"}, {"source": "wiki"}, {"source": "runbook"}],
)

# Query
results = collection.query(
    query_embeddings=[[0.15] * 768],   # replace with real query vector
    n_results=3,
    include=["documents", "metadatas", "distances"],
    where={"source": "runbook"},       # metadata filter
)
print(results["documents"][0])
```

Chroma handles embedding generation for you if you pass `embedding_function` — but use your own so you control the model and can swap it. Do not let Chroma auto-download models silently.

### FAISS — offline research and benchmarking

Use FAISS when you need precise control over the ANN algorithm, want to serialize and load indices from disk, or are benchmarking recall/latency curves. Not a database — no persistence layer, no metadata filtering, no HTTP server.

```python
import faiss

# Save and load
faiss.write_index(index, "my_index.faiss")
index = faiss.read_index("my_index.faiss")
```

### pgvector — production with metadata filtering

When your application already runs PostgreSQL (or Supabase/Neon), pgvector adds a native vector type and HNSW/IVF indices. The advantage: complex metadata filtering via SQL without a separate vector database:

```sql
-- Schema
CREATE TABLE documents (
    id      TEXT PRIMARY KEY,
    source  TEXT,
    content TEXT,
    vec     VECTOR(768)
);
CREATE INDEX ON documents USING hnsw (vec vector_cosine_ops);

-- Semantic search filtered by source
SELECT id, content, 1 - (vec <=> $1::vector) AS score
FROM documents
WHERE source = 'runbook'
ORDER BY vec <=> $1::vector
LIMIT 5;
```

```python
import psycopg2, json

def pgvector_search(conn, query_vec: list[float], n: int = 5) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT id, content, 1 - (vec <=> %s::vector) AS score
            FROM documents
            ORDER BY vec <=> %s::vector
            LIMIT %s
            """,
            (query_vec, query_vec, n),
        )
        return [{"id": r[0], "content": r[1], "score": r[2]} for r in cur.fetchall()]
```

---

## The chunk-to-vector pipeline

End-to-end: from a directory of documents to a queryable Chroma collection.

```python
import ollama
import chromadb
import httpx
from pathlib import Path

EMBED_MODEL = "nomic-embed-text"
CHROMA_PATH = ".chroma"
COLLECTION_NAME = "docs"

ollama_client = ollama.Client()
chroma_client = chromadb.PersistentClient(path=CHROMA_PATH)
collection = chroma_client.get_or_create_collection(
    name=COLLECTION_NAME,
    metadata={"hnsw:space": "cosine"},
)


def embed(text: str) -> list[float]:
    return ollama_client.embeddings(model=EMBED_MODEL, prompt=text).embedding


def embed_batch(texts: list[str]) -> list[list[float]]:
    resp = httpx.post(
        "http://localhost:11434/api/embed",
        json={"model": EMBED_MODEL, "input": texts},
        timeout=120.0,
    )
    resp.raise_for_status()
    return resp.json()["embeddings"]


def chunk_text(text: str, size: int = 512, overlap: int = 64) -> list[str]:
    """Naive fixed-character chunker with overlap. Module 03 covers smarter strategies."""
    chunks = []
    start = 0
    while start < len(text):
        end = start + size
        chunks.append(text[start:end].strip())
        start += size - overlap
    return [c for c in chunks if c]


def ingest_file(path: Path, batch_size: int = 32) -> int:
    """Returns number of chunks ingested."""
    text = path.read_text(encoding="utf-8", errors="replace")
    chunks = chunk_text(text)
    ids = [f"{path.stem}_{i}" for i in range(len(chunks))]
    metas = [{"source": path.name, "chunk_index": i} for i in range(len(chunks))]

    # Batch embedding is much faster than one-by-one
    for i in range(0, len(chunks), batch_size):
        batch_chunks = chunks[i : i + batch_size]
        batch_ids = ids[i : i + batch_size]
        batch_metas = metas[i : i + batch_size]
        batch_vecs = embed_batch(batch_chunks)

        collection.add(
            ids=batch_ids,
            documents=batch_chunks,
            embeddings=batch_vecs,
            metadatas=batch_metas,
        )

    return len(chunks)


def search(query: str, n: int = 5) -> list[dict]:
    q_vec = embed(query)
    results = collection.query(
        query_embeddings=[q_vec],
        n_results=n,
        include=["documents", "metadatas", "distances"],
    )
    return [
        {
            "text": doc,
            "source": meta["source"],
            "score": round(1 - dist, 4),   # Chroma returns L2 distance for cosine; convert
        }
        for doc, meta, dist in zip(
            results["documents"][0],
            results["metadatas"][0],
            results["distances"][0],
        )
    ]


if __name__ == "__main__":
    docs_dir = Path("./docs")
    for md_file in docs_dir.glob("**/*.md"):
        n = ingest_file(md_file)
        print(f"Ingested {md_file.name}: {n} chunks")

    hits = search("pod OOMKilled troubleshooting", n=3)
    for h in hits:
        print(f"[{h['score']:.3f}] ({h['source']}) {h['text'][:120]!r}")
```

> **Idempotency.** The `collection.add` call above will fail if the same `id` already exists. In a real pipeline, either use `collection.upsert` (slower but safe for re-runs) or track a hash of each file's mtime and skip re-indexing unchanged files.

---

## Debugging embeddings & vector search

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Semantically similar queries return unrelated results | Vectors are not normalized before indexing; dot-product index treating magnitude as signal | `faiss.normalize_L2(vecs)` before `index.add`; re-initialize Chroma collection with `{"hnsw:space": "cosine"}` |
| Dimension mismatch error at query time | Query was embedded with a different model than the index | Store model name as collection metadata; assert at ingest AND query |
| High recall in tests, poor recall in production | Test corpus is small/homogeneous; real queries use different vocabulary | Evaluate with real production queries; consider hybrid BM25 + vector search |
| Queries are slow (> 500 ms) | Index too large for RAM (swapping); or HNSW `efSearch` too high | Reduce `efSearch`; quantize with `IndexIVFPQ`; pre-load index on startup |
| Identical strings return similarity < 1.0 | Floating-point rounding in normalization | Expected — this is a float32 precision artifact; treat > 0.999 as identical |
| Chroma returns wrong documents after re-running ingestion | Duplicate IDs accumulated across runs — old and new chunks coexist | Use `collection.upsert` or `collection.delete(ids=[...])` before re-ingesting |
| Scores all cluster between 0.7 and 0.8 — no discrimination | Model is too generic for your domain; or chunk length mismatch | Fine-tune an embedding model on your domain, or switch to a domain-specific model |

### Diagnose normalization bug

```python
import numpy as np

def check_normalization(vecs: list[list[float]]) -> None:
    """Fail fast if any vector is not unit-length."""
    arr = np.array(vecs, dtype=np.float32)
    norms = np.linalg.norm(arr, axis=1)
    bad = np.where(np.abs(norms - 1.0) > 0.01)[0]
    if len(bad) > 0:
        raise ValueError(
            f"{len(bad)} vectors are not unit-length. "
            f"Norms range: [{norms.min():.4f}, {norms.max():.4f}]. "
            f"Call faiss.normalize_L2(vecs) before indexing."
        )
    print(f"All {len(vecs)} vectors are unit-length. ✓")
```

### Diagnose dimension mismatch

```python
import chromadb

client = chromadb.PersistentClient(path=".chroma")
coll = client.get_collection("docs")

# Query the collection's actual dimensionality
sample = coll.peek(1)
if sample["embeddings"]:
    actual_dim = len(sample["embeddings"][0])
    print(f"Index dimension: {actual_dim}")
    # If this differs from your current embed() output, you must re-index
```

### Measure recall at k

```python
def recall_at_k(
    ground_truth: dict[str, list[str]],  # query -> relevant doc ids
    retrieval_fn,                          # query -> list of doc ids
    k: int = 5,
) -> float:
    scores = []
    for query, relevant in ground_truth.items():
        retrieved = retrieval_fn(query)[:k]
        hits = len(set(retrieved) & set(relevant))
        scores.append(hits / len(relevant))
    return sum(scores) / len(scores)
```

> **War story.** At SAP I built a semantic search over internal support tickets. Precision looked fine in offline evaluation (0.83 on a 200-query test set), but production users complained the results were irrelevant. The root cause: the ticket corpus had been partially re-indexed with a batch script that a colleague wrote independently. My script called `faiss.normalize_L2` before indexing; their script did not. The index contained a mix of unit-length vectors (my batches) and un-normalized vectors (their batches). Dot-product similarity over un-normalized vectors mixes direction and magnitude — documents with long content that happened to produce large-magnitude vectors were scoring disproportionately high regardless of semantic relevance. The fix was a `check_normalization()` call at ingestion time that raises immediately on any non-unit vector. Re-indexing took 20 minutes. The `check_normalization()` function is now the first line of every ingestion pipeline I write.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Explain, geometrically, why cosine similarity is preferred over L2 distance for text embeddings — what property of text documents makes magnitude a misleading signal?
2. State the exact failure mode you get when half your index is normalized and half is not, and why the output "looks plausible" instead of throwing an error.
3. Write the three-line FAISS normalization sequence (create float32 array, normalize in-place, add to index) from memory.
4. Name the trade-off HNSW makes vs exact search, and identify the two parameters that control that trade-off.
5. Explain why switching embedding models mid-stream requires a full re-index — not just re-querying.
6. Write a batch ingestion function that skips re-embedding unchanged files using mtime hashing.
7. Diagnose a "high test recall, low production recall" problem and propose two interventions.
8. State which vector database you would use for: a production API with metadata filters; an offline research benchmark; a 2-hour prototype.

➡ Next: **Retrieval-Augmented Generation** — combining everything: the retrieval pipeline from this module feeds a generation step, with chunking strategies, reranking, token budget management, and citations baked in.
