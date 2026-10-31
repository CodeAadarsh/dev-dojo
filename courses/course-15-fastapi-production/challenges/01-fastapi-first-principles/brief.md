# FastAPI First Principles

A junior dev shipped a product catalog API. It runs without crashing, but the PR reviewer left a comment: *"Status codes are wrong, there's no input validation, and the 404 returns 200. Not merging."*

Your job: fix `main.py` so the eight-test harness passes end-to-end.

## Context

`setup.sh` plants the starter in your work directory:

```
~/.kube-dojo-work/01-fastapi-first-principles/
├── main.py          # FastAPI app — routing exists, models and behaviour are wrong
└── tests/
    └── test_catalog.py   # eight-test harness; your fix must pass all of them
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/01-fastapi-first-principles
python3 -m venv .venv && . .venv/bin/activate
pip install fastapi "uvicorn[standard]" httpx pytest pydantic sqlalchemy pyjwt
```

## Mission

The starter has four deliberate defects:

| Defect | Location | Correct behaviour |
|--------|----------|-------------------|
| `status_code=200` on POST | `@app.post` decorator | Must be `201 Created` |
| Body typed as `dict` | `create_product` parameter | Must be a `ProductCreate(BaseModel)` with `price: float = Field(gt=0)` |
| Query param typed as `str` | `in_stock` in `list_products` | Must be `Optional[bool]` so FastAPI coerces `?in_stock=true` |
| Missing product returns `200` with error dict | `get_product` body | Must `raise HTTPException(status_code=404)` |

Define two Pydantic v2 models:

```
ProductCreate   name (str), category (str), price (float, > 0), in_stock (bool, default True)
Product         all fields from ProductCreate plus id (int)
```

Update all three endpoints to use these models. The `list_products` filter must compare `item.in_stock` to the boolean `True`/`False`, not to a string.

The harness asserts:

| Test | Requirement |
|------|-------------|
| `test_create_returns_201` | POST /products → 201 |
| `test_create_assigns_id` | response body contains `id` |
| `test_create_validates_price_positive` | price ≤ 0 → 422 |
| `test_create_requires_name` | missing name → 422 |
| `test_list_returns_list` | GET /products → 200, body is a JSON array |
| `test_in_stock_filter_true` | GET /products?in_stock=true → only in-stock items |
| `test_get_product_returns_200` | GET /products/{id} → 200 with correct name |
| `test_get_missing_returns_404` | GET /products/999999 → 404 |

Pydantic's automatic validation handles the 422s for you — once the models are declared, there is nothing else to wire.

## Why this matters

Returning 200 for a missing resource means the caller has to inspect the body to detect an error. Every SDK, retry policy, and monitoring alert is calibrated on status codes, not body content. Getting the code wrong at the framework level means your operational tooling lies to you silently.

## Verify

```bash
bash courses/course-15-fastapi-production/challenges/01-fastapi-first-principles/verify.sh
```

All eight tests green → flag printed.
